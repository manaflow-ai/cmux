import Foundation

/// Event-driven state machine for an optional leader/prefix shortcut layer.
///
/// The router is intentionally AppKit-free. The host turns an ``NSEvent`` into
/// a ``ShortcutStroke``, supplies the currently eligible bindings, and maps an
/// executed action identifier back to its shared action executor. Keeping the
/// state machine here makes the pass-through contract independently testable
/// and lets non-AppKit hosts (for example a future plugin surface) reuse it.
public struct ShortcutPrefixChordRouter: Sendable {
    /// Default maximum interval, in seconds, between prefix and suffix.
    public static let defaultTimeout: TimeInterval = 0.8

    /// The result of offering one key event to the router.
    public enum EventResult: Sendable, Equatable {
        /// No prefix layer consumed or armed for this event.
        case passThrough

        /// The prefix was consumed and the router is waiting for one suffix.
        case armed(available: [ShortcutPrefixChordBinding], expiresAt: TimeInterval)

        /// A unique suffix selected an action. The host owns execution.
        case executed(ShortcutPrefixChordBinding)

        /// The pending state ended without dispatching an action.
        /// `consume` is true for Escape, which is an explicit cancel gesture.
        case disarmed(consume: Bool)

        /// The event belongs to the prefix layer but cannot resolve uniquely.
        /// It must be offered to the terminal unchanged, while ordinary cmux
        /// shortcut routing must not run for that same event. This covers an
        /// unmatched suffix and a prefix whose eligible table is ambiguous.
        case mismatchPassThrough
    }

    /// The result of offering an event together with its deduplication status.
    public struct HandleResult: Sendable, Equatable {
        /// The state-machine decision for the event.
        public let result: EventResult
        /// True when the same event identity was already offered earlier.
        public let wasDuplicate: Bool

        /// Creates a routed event result.
        public init(result: EventResult, wasDuplicate: Bool) {
            self.result = result
            self.wasDuplicate = wasDuplicate
        }
    }

    private struct Pending: Sendable, Equatable {
        let windowID: Int?
        let expiresAt: TimeInterval
        let bindings: [ShortcutPrefixChordBinding]
        let availableBindings: [ShortcutPrefixChordBinding]
    }

    private var prefix: ShortcutStroke?
    private let timeout: TimeInterval
    private var pending: Pending?
    private var recentEvents = ShortcutPrefixChordEventLedger<EventResult>()

    /// Creates an idle router. A `nil` prefix is the default-off state.
    public init(
        prefix: ShortcutStroke? = nil,
        timeout: TimeInterval = ShortcutPrefixChordRouter.defaultTimeout
    ) {
        self.prefix = Self.normalizedPrefix(prefix)
        self.timeout = max(timeout, 0.001)
    }

    /// Replaces the configured prefix without changing the timeout.
    /// Changing or disabling the prefix always disarms a pending chord.
    public mutating func setPrefix(_ prefix: ShortcutStroke?) {
        let normalized = Self.normalizedPrefix(prefix)
        if self.prefix == normalized {
            // A disabled router should be an observationally idle state even
            // if a host recovered from an interrupted settings update with a
            // stale pending value or replay ledger. Keep this idempotent call
            // safe and deterministic rather than relying on the caller to
            // notice that the prefix value itself did not change.
            if normalized == nil {
                pending = nil
                recentEvents.removeAll()
            }
            return
        }
        self.prefix = normalized
        pending = nil
        recentEvents.removeAll()
    }

    /// The canonical configured prefix, or nil when disabled.
    public var configuredPrefix: ShortcutStroke? { prefix }
    /// Whether a prefix has been consumed and a suffix is pending.
    public var isArmed: Bool { pending != nil }
    /// The eligible suffix bindings captured when the router armed.
    public var availableBindings: [ShortcutPrefixChordBinding] {
        pending?.availableBindings ?? []
    }
    /// The monotonic deadline for the pending suffix, if armed.
    public var deadline: TimeInterval? { pending?.expiresAt }
    /// The window that owns the pending suffix, when one was captured.
    /// Hosts use this to collect a fresh eligible table when a new window
    /// presses the prefix before the old window's timeout has elapsed.
    public var pendingWindowID: Int? { pending?.windowID }

    /// Returns whether `stroke` is the currently configured prefix.  Hosts can
    /// use this cheap predicate to avoid rebuilding a focus/action binding table
    /// for ordinary terminal typing while the optional layer is enabled.
    public func matchesConfiguredPrefix(_ stroke: ShortcutStroke) -> Bool {
        guard let prefix else { return false }
        return Self.sameStroke(prefix, stroke)
    }

    /// Offers one key event to the state machine.
    ///
    /// `bindings` should contain the actions valid in the host's current focus
    /// context. The router snapshots the eligible table when it arms, so the
    /// HUD and the following key use one coherent view of the available keys.
    /// A window change never carries a pending chord across to another window.
    public mutating func handle(
        stroke: ShortcutStroke,
        now: TimeInterval,
        windowID: Int? = nil,
        isEscape: Bool = false,
        bindings: [ShortcutPrefixChordBinding],
        eventID: ShortcutPrefixChordEventIdentity? = nil
    ) -> EventResult {
        handleOnce(
            stroke: stroke,
            now: now,
            windowID: windowID,
            isEscape: isEscape,
            bindings: bindings,
            eventID: eventID
        ).result
    }

    /// Offers one event and reports whether its identity was already resolved.
    ///
    /// Hosts should use this entry point when an AppKit event can cross more
    /// than one routing seam. A duplicate returns the original decision without
    /// changing pending state, so an action cannot execute twice or have its
    /// timeout extended by a replay.
    public mutating func handleOnce(
        stroke: ShortcutStroke,
        now: TimeInterval,
        windowID: Int? = nil,
        isEscape: Bool = false,
        bindings: [ShortcutPrefixChordBinding],
        eventID: ShortcutPrefixChordEventIdentity? = nil
    ) -> HandleResult {
        // Timer delivery is event-driven and can race a replay at the same
        // run-loop turn. Expire the state before consulting the replay ledger
        // so an old leader event cannot keep the router logically armed past
        // its deadline. The ledger still returns the original consumed result
        // below, preventing that replay from leaking the already-consumed
        // leader into the terminal.
        _ = expire(now: now)
        if let eventID,
           let previous = recentEvents.lookup(eventID) {
            // A physical event can be replayed after the platform deadline
            // has elapsed. It must still resolve exactly once: re-processing
            // an old prefix here would arm a fresh deadline and make a replay
            // extend the chord window. The real deadline is handled by
            // ``expire(now:)`` or by the next distinct event.
            return HandleResult(result: previous, wasDuplicate: true)
        }
        let result = handleUntracked(
            stroke: stroke,
            now: now,
            windowID: windowID,
            isEscape: isEscape,
            bindings: bindings
        )
        if let eventID, Self.shouldRemember(result) {
            recentEvents.record(result, for: eventID)
        }
        return HandleResult(result: result, wasDuplicate: false)
    }

    /// Resolves an event that cannot be represented by ``ShortcutStroke``.
    ///
    /// Media/system-defined events and malformed synthetic events still need
    /// to cancel an armed layer. When the event belongs to the pending window,
    /// the result is a terminal pass-through mismatch; a different window has
    /// no ownership of the pending layer and receives ordinary pass-through.
    /// The event identity participates in the same exactly-once ledger as
    /// representable strokes.
    public mutating func handleUnsupportedOnce(
        now: TimeInterval,
        windowID: Int? = nil,
        eventID: ShortcutPrefixChordEventIdentity? = nil
    ) -> HandleResult {
        // An unsupported event can be the first distinct offer after the
        // deadline (for example a replayed system-defined event). Expire the
        // pending state before consulting the ledger so an old recorded
        // decision cannot leave the router logically armed past its timeout.
        _ = expire(now: now)
        if let eventID, let previous = recentEvents.lookup(eventID) {
            return HandleResult(result: previous, wasDuplicate: true)
        }
        let result: EventResult
        if let pending {
            self.pending = nil
            if pending.windowID == windowID, now < pending.expiresAt {
                result = .mismatchPassThrough
            } else {
                result = .passThrough
            }
        } else {
            result = .passThrough
        }

        if let eventID, Self.shouldRemember(result) {
            recentEvents.record(result, for: eventID)
        }
        return HandleResult(result: result, wasDuplicate: false)
    }

    /// Records a context-bypassed event without changing pending state.
    ///
    /// Hosts use this when a modal, browser-focus, or IME ownership boundary
    /// deliberately keeps cmux from inspecting the event. Recording the
    /// pass-through decision prevents a later AppKit replay from running the
    /// ordinary cmux dispatcher a second time.
    public mutating func rememberBypassedEvent(
        eventID: ShortcutPrefixChordEventIdentity
    ) -> HandleResult {
        if let previous = recentEvents.lookup(eventID) {
            return HandleResult(result: previous, wasDuplicate: true)
        }
        let result: EventResult = .passThrough
        recentEvents.record(result, for: eventID)
        return HandleResult(result: result, wasDuplicate: false)
    }

    private mutating func handleUntracked(
        stroke: ShortcutStroke,
        now: TimeInterval,
        windowID: Int?,
        isEscape: Bool,
        bindings: [ShortcutPrefixChordBinding]
    ) -> EventResult {
        if let pending {
            if pending.windowID != windowID || now >= pending.expiresAt {
                self.pending = nil
            } else {
                self.pending = nil
                if isEscape || Self.isEscapeStroke(stroke) {
                    return .disarmed(consume: true)
                }
                if let match = Self.uniqueMatch(pending.bindings, stroke: stroke) {
                    return .executed(match)
                }
                return .mismatchPassThrough
            }
        }

        guard let prefix,
              !isEscape,
              Self.sameStroke(prefix, stroke) else {
            return .passThrough
        }

        let eligible = Self.deduplicatedBindings(
            bindings.filter {
                Self.sameStroke($0.firstStroke, prefix)
                    && !$0.secondStroke.canonicalized().key.isEmpty
            }
        )
        guard !eligible.isEmpty else { return .passThrough }
        let available = Self.uniqueBindings(eligible)
        guard !available.isEmpty else {
            // Do not let the legacy per-action chord matcher choose one of an
            // ambiguous set after this router has deliberately failed closed.
            return .mismatchPassThrough
        }

        let expiresAt = now + timeout
        pending = Pending(
            windowID: windowID,
            expiresAt: expiresAt,
            bindings: eligible,
            availableBindings: available
        )
        return .armed(available: available, expiresAt: expiresAt)
    }

    /// Disarms after an event-driven deadline callback.
    ///
    /// The host schedules this callback with its platform timer; the router
    /// never sleeps or polls. Returns `nil` when the deadline has not arrived.
    public mutating func expire(now: TimeInterval) -> EventResult? {
        guard let pending, now >= pending.expiresAt else { return nil }
        self.pending = nil
        return .disarmed(consume: false)
    }

    /// Explicitly clears the pending state (window/app lifecycle or settings
    /// changes). No key event is consumed by this operation.
    public mutating func reset() {
        pending = nil
        recentEvents.removeAll()
    }

    /// Idle pass-through is deliberately not retained. Recording every normal
    /// terminal keystroke would make a later AppKit seam treat a first offer as
    /// a replay and skip ordinary shortcut routing. Only decisions that claim
    /// ownership, cancel an armed layer, or explicitly bypass a suffix need
    /// exactly-once replay protection; ``rememberBypassedEvent`` handles the
    /// explicit context-bypass case separately.
    private static func shouldRemember(_ result: EventResult) -> Bool {
        switch result {
        case .passThrough:
            return false
        case let .disarmed(consume):
            return consume
        case .armed, .executed, .mismatchPassThrough:
            return true
        }
    }

    private static func normalizedPrefix(_ prefix: ShortcutStroke?) -> ShortcutStroke? {
        guard let prefix else { return nil }
        return ShortcutPrefixPolicy().normalized(prefix)
    }

    private static func uniqueBindings(
        _ bindings: [ShortcutPrefixChordBinding]
    ) -> [ShortcutPrefixChordBinding] {
        // The HUD only advertises bindings that win at least one suffix. The
        // pending table retains every eligible binding so a suffix that is
        // ambiguous with a different candidate still fails closed at runtime.
        var candidatesBySuffix: [StrokeIdentity: [ShortcutPrefixChordBinding]] = [:]
        for binding in bindings {
            for stroke in representativeStrokes(for: binding) {
                candidatesBySuffix[StrokeIdentity(stroke), default: []].append(binding)
            }
        }

        var winners = Set<ShortcutPrefixChordBinding>()
        for candidates in candidatesBySuffix.values {
            if let winner = uniqueWinner(candidates) {
                winners.insert(winner)
            }
        }
        return winners
            .sorted {
                let lhs = Self.suffixIdentity($0)
                let rhs = Self.suffixIdentity($1)
                if lhs != rhs { return lhs < rhs }
                if $0.hasPriorityRouting != $1.hasPriorityRouting {
                    return $0.hasPriorityRouting
                }
                return $0.actionID < $1.actionID
            }
    }

    private static func deduplicatedBindings(
        _ bindings: [ShortcutPrefixChordBinding]
    ) -> [ShortcutPrefixChordBinding] {
        var seen = Set<ShortcutPrefixChordBinding>()
        return bindings.filter { seen.insert($0).inserted }
    }

    private static func uniqueMatch(
        _ bindings: [ShortcutPrefixChordBinding],
        stroke: ShortcutStroke
    ) -> ShortcutPrefixChordBinding? {
        let matches = bindings.filter { Self.matchesSuffix($0, stroke: stroke) }
        return uniqueWinner(matches)
    }

    private static func uniqueWinner(
        _ matches: [ShortcutPrefixChordBinding]
    ) -> ShortcutPrefixChordBinding? {
        guard !matches.isEmpty else { return nil }
        // Existing cmux shortcut routing gives a priority action first refusal
        // in its eligible context. Permit exactly one priority winner, but do
        // not guess when two priority actions (or two ordinary actions) match.
        let highestPriority = matches.contains { $0.hasPriorityRouting }
        let winners = matches.filter { $0.hasPriorityRouting == highestPriority }
        guard winners.count == 1 else { return nil }
        return winners[0]
    }

    private static func representativeStrokes(
        for binding: ShortcutPrefixChordBinding
    ) -> [ShortcutStroke] {
        guard binding.matchesNumberedDigits,
              isNumberedDigit(binding.secondStroke.key) else {
            return [binding.secondStroke]
        }
        let expected = binding.secondStroke
        return (1...9).map { digit in
            ShortcutStroke(
                key: String(digit),
                command: expected.command,
                shift: expected.shift,
                option: expected.option,
                control: expected.control,
                keyCode: expected.keyCode
            )
        }
    }

    private static func suffixIdentity(_ binding: ShortcutPrefixChordBinding) -> StrokeIdentity {
        var stroke = binding.secondStroke
        if binding.matchesNumberedDigits, isNumberedDigit(stroke.key) {
            stroke = ShortcutStroke(
                key: "1",
                command: stroke.command,
                shift: stroke.shift,
                option: stroke.option,
                control: stroke.control,
                keyCode: stroke.keyCode
            )
        }
        return StrokeIdentity(stroke)
    }

    private static func matchesSuffix(
        _ binding: ShortcutPrefixChordBinding,
        stroke: ShortcutStroke
    ) -> Bool {
        guard binding.matchesNumberedDigits,
              isNumberedDigit(binding.secondStroke.key) else {
            return sameStroke(binding.secondStroke, stroke)
        }

        guard isNumberedDigit(stroke.key) else { return false }
        let expected = binding.secondStroke
        return expected.command == stroke.command
            && expected.shift == stroke.shift
            && expected.option == stroke.option
            && expected.control == stroke.control
    }

    private static func isNumberedDigit(_ key: String) -> Bool {
        guard let digit = Int(key) else { return false }
        return (1...9).contains(digit)
    }

    private static func isEscapeStroke(_ stroke: ShortcutStroke) -> Bool {
        let key = stroke.canonicalized().key.lowercased()
        return key == "escape" || key == "\u{1b}"
    }

    private static func sameStroke(_ lhs: ShortcutStroke, _ rhs: ShortcutStroke) -> Bool {
        StrokeIdentity(lhs) == StrokeIdentity(rhs)
    }

    private struct StrokeIdentity: Hashable, Comparable, Sendable {
        let key: String
        let command: Bool
        let shift: Bool
        let option: Bool
        let control: Bool

        init(_ stroke: ShortcutStroke) {
            let canonical = stroke.canonicalized()
            key = canonical.key.lowercased()
            command = canonical.command
            shift = canonical.shift
            option = canonical.option
            control = canonical.control
        }

        static func < (lhs: StrokeIdentity, rhs: StrokeIdentity) -> Bool {
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            if lhs.command != rhs.command { return !lhs.command && rhs.command }
            if lhs.shift != rhs.shift { return !lhs.shift && rhs.shift }
            if lhs.option != rhs.option { return !lhs.option && rhs.option }
            if lhs.control != rhs.control { return !lhs.control && rhs.control }
            return false
        }
    }
}
