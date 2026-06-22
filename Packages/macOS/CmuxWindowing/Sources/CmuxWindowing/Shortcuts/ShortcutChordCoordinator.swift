/// Owns the configured-shortcut chord state machine for two-stroke ("chorded")
/// keyboard shortcuts.
///
/// A chorded shortcut fires only after two strokes are typed in order: a prefix
/// stroke arms the chord, and a matching second stroke in the *same* window
/// completes it. This coordinator holds the small amount of mutable state that
/// spans those two key events:
///
/// - ``pendingChord`` — set when a prefix stroke matched, cleared once the next
///   key event is processed (whether or not it completed the chord).
/// - ``activePrefixForCurrentEvent`` — the prefix that is "live" for the event
///   currently being dispatched, set by ``prepareForEvent(windowNumber:)`` at
///   the top of each shortcut-handling turn and reset to `nil` at the end of
///   that turn by the caller. Per-event shortcut matchers read this to decide
///   whether to match a second stroke instead of a first stroke.
///
/// ## Why this lives in CmuxWindowing, not the app target
///
/// Chord scoping is window identity: the second stroke must land in the same
/// window (`windowNumber`) that armed the prefix, so this is per-window
/// interaction state in the broad windowing/app-shell domain. The state is a
/// tiny value pair; the per-keystroke dispatch (the large shortcut `switch`)
/// stays in the app target and reaches this state through a single held
/// reference, so the keystroke hot path takes one property access rather than
/// any new allocation or fan-out.
///
/// ## Generic over the app's stroke/shortcut types
///
/// The app target owns its own `ShortcutStroke`/`StoredShortcut` value types and
/// their NSEvent-matching logic, so this coordinator is generic over the stroke
/// type and accepts the matching predicate as a closure. It imposes no protocol
/// on the app types and pulls in no settings dependency: it only holds and
/// transitions the chord state.
///
/// ## Isolation
///
/// `@MainActor` because every mutator runs on the main thread inside the
/// AppKit local key-event monitor's handler, co-locating the state with its
/// only callers (mirrors ``WindowCoordinator``'s isolation ruling: state lives
/// where its callers live, so no cross-actor bridge is needed).
///
/// ## Behavior preservation
///
/// The app target resolves which shortcuts are chord candidates and supplies
/// the per-event stroke matcher, the first-stroke accessor, and `windowNumber`,
/// exactly matching the legacy `AppDelegate` logic; this type only holds and
/// transitions the state. The arm scan, the prefix-activation rule, and the
/// clear semantics are byte-faithful relocations of the former
/// `pendingConfiguredShortcutChord` / `activeConfiguredShortcutChordPrefixForCurrentEvent`
/// handling.
@MainActor
public final class ShortcutChordCoordinator<Stroke: Equatable & Sendable> {
    /// The armed prefix awaiting its second stroke, or `nil` when no chord is
    /// pending. Cleared at the start of each event by
    /// ``prepareForEvent(windowNumber:)``.
    public private(set) var pendingChord: PendingShortcutChord<Stroke>?

    /// The chord prefix that is live for the event currently being dispatched,
    /// or `nil` when the current event is not a chord completion. Set by
    /// ``prepareForEvent(windowNumber:)`` and reset to `nil` by the caller at
    /// the end of the dispatch turn.
    public var activePrefixForCurrentEvent: Stroke?

    /// Creates an empty coordinator with no pending chord. The app target holds
    /// one instance and wires it at the composition root.
    public init() {}

    /// Clears all chord state: drops any pending prefix and the active prefix.
    ///
    /// Faithful relocation of the legacy `clearConfiguredShortcutChordState()`.
    public func clear() {
        pendingChord = nil
        activePrefixForCurrentEvent = nil
    }

    /// Begins a dispatch turn for an event originating in `windowNumber`.
    ///
    /// If a chord is pending and was armed in the same window, its prefix
    /// becomes the ``activePrefixForCurrentEvent`` (so this event can complete
    /// the chord); otherwise the active prefix is cleared. The pending chord is
    /// always consumed (a prefix arms exactly one subsequent event).
    ///
    /// Faithful relocation of the legacy prefix-activation block that ran at the
    /// top of `handleCustomShortcut` and `handleBrowserPopupCloseShortcutKeyEquivalent`.
    public func prepareForEvent(windowNumber: Int?) {
        if let pendingChord, pendingChord.windowNumber == windowNumber {
            activePrefixForCurrentEvent = pendingChord.firstStroke
        } else {
            activePrefixForCurrentEvent = nil
        }
        pendingChord = nil
    }

    /// Arms a chord prefix if any of `candidates` is a chorded shortcut whose
    /// first stroke matches the current event.
    ///
    /// The caller supplies `isChord` (whether a candidate is a two-stroke
    /// binding), `firstStroke` (the candidate's opening stroke), and
    /// `firstStrokeMatches` (which closes over the `NSEvent` and the layout-aware
    /// matcher), so this type stays free of the app's stroke logic. Duplicate
    /// candidates are scanned once, preserving the legacy de-duplication on the
    /// whole shortcut. On the first match the prefix is recorded under
    /// `windowNumber` and `true` is returned; otherwise `false`.
    ///
    /// Faithful relocation of the legacy `armConfiguredShortcutChordIfNeeded`.
    public func armIfNeeded<Shortcut: Hashable>(
        candidates: [Shortcut],
        windowNumber: Int?,
        isChord: (Shortcut) -> Bool,
        firstStroke: (Shortcut) -> Stroke,
        firstStrokeMatches: (Stroke) -> Bool
    ) -> Bool {
        var seen = Set<Shortcut>()
        for shortcut in candidates {
            guard seen.insert(shortcut).inserted else { continue }
            guard isChord(shortcut) else { continue }
            let stroke = firstStroke(shortcut)
            if firstStrokeMatches(stroke) {
                pendingChord = PendingShortcutChord(
                    firstStroke: stroke,
                    windowNumber: windowNumber
                )
                return true
            }
        }
        return false
    }
}
