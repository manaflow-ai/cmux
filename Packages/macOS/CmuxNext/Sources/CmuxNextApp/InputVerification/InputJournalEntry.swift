/// One record of the input journal (plans/cmux-next/input-spec.md section 3):
/// an input event, a focus or attach transition, or a diagnostic marker,
/// with a monotonic timestamp and the cmux window it concerns.
///
/// Privacy: key records carry the key code and modifier classes only.
/// `characters` is filled only when the user opted in
/// (`CMUX_NEXT_INPUT_JOURNAL_CHARACTERS=1`). Attach records carry byte
/// counts, never bytes. Ids are daemon pane, tab and surface ids.
nonisolated struct InputJournalEntry: Hashable, Sendable, Codable {
    /// Strictly increasing per process; gaps mean the ring overwrote entries.
    var seq: UInt64
    /// `CLOCK_UPTIME_RAW` nanoseconds at capture.
    var uptimeNanos: UInt64
    /// `WindowState.id` of the cmux window (a Chromium page window counts as
    /// its parent); nil for panels and app-wide records.
    var window: String?
    var kind: Kind

    enum Kind: Hashable, Sendable, Codable {
        case key(Key)
        case mouse(Mouse)
        case windowKey(Bool)
        case appActive(Bool)
        /// A focus state machine input and the state it produced.
        case focus(FocusEvent, after: FocusDigest)
        /// The window's full focus state, so replay can start mid-ring.
        case focusCheckpoint(FocusState)
        /// An AppKit responder report; `suppressed` when it was the echo of
        /// the applier's own `makeFirstResponder` (not reduced).
        case responder(FocusEvent.Responder, suppressed: Bool)
        /// The applier gave or took page focus (WebKit or Chromium).
        case page(tab: String, focused: Bool, engine: String)
        case attach(Attach)
        /// A cmux window moved or resized (screen points, bottom-left
        /// origin; a run of moves is merged into one entry).
        case windowFrame(x: Double, y: Double, width: Double, height: Double)
        /// The invariant monitor recorded a desync report.
        case desync([String])
        /// Free text from automation (`debug.journal` with `marker`).
        case marker(String)
    }

    enum KeyPhase: String, Hashable, Sendable, Codable {
        case down, up, flags
    }

    struct Key: Hashable, Sendable, Codable {
        var phase: KeyPhase
        var keyCode: UInt16
        var modifiers: ModifierClasses
        var isRepeat: Bool
        /// Only with the user's opt-in.
        var characters: String?
    }

    /// Device-independent modifier classes (no characters, no key identity).
    struct ModifierClasses: OptionSet, Hashable, Sendable, Codable {
        var rawValue: UInt8
        static let command = ModifierClasses(rawValue: 1 << 0)
        static let shift = ModifierClasses(rawValue: 1 << 1)
        static let option = ModifierClasses(rawValue: 1 << 2)
        static let control = ModifierClasses(rawValue: 1 << 3)
        static let function = ModifierClasses(rawValue: 1 << 4)
        static let capsLock = ModifierClasses(rawValue: 1 << 5)

        var names: [String] {
            [(Self.command, "cmd"), (.shift, "shift"), (.option, "option"), (.control, "ctrl"), (.function, "fn"), (.capsLock, "caps")]
                .compactMap { contains($0.0) ? $0.1 : nil }
        }
    }

    enum MousePhase: String, Hashable, Sendable, Codable {
        case down, up, drag, scroll
    }

    struct Mouse: Hashable, Sendable, Codable {
        var phase: MousePhase
        /// 0 left, 1 right, 2 other.
        var button: Int
        /// Window-local points from the top-left of the cmux window (the
        /// coordinates `debug.mouse` takes). For a drag or scroll run, the
        /// last location.
        var x: Double
        var y: Double
        var clickCount: Int
        var modifiers: ModifierClasses
        /// Consecutive drag or scroll events merged into this entry.
        var count: Int = 1
        /// Summed scroll deltas.
        var dx: Double = 0
        var dy: Double = 0
    }

    struct Attach: Hashable, Sendable, Codable {
        var surface: String
        /// `start`, `opened`, `openFailed`, `replay`, `input`, `resize:CxR`, `grid:CxR`, `focused`,
        /// `visible`, `hidden`, `ended:<reason>`, `close`.
        var event: String
        /// Link identity (per process), when the event names one.
        var link: Int?
        var attempt: Int?
        /// Input bytes (never the bytes themselves).
        var bytes: Int = 0
        /// Machine phase after the event.
        var phase: String
        var droppedBytes: Int = 0
    }
}

/// What `debug.focus` and replay compare after each focus transition.
nonisolated struct FocusDigest: Hashable, Sendable, Codable {
    var resolved: String
    var pane: String?
    var tab: String?
    var target: FocusState.Target
    var overlays: [FocusState.Overlay]
    var generation: UInt64
    var windowKey: Bool

    init(_ state: FocusState) {
        let resolved = state.resolved
        self.resolved = resolved.kind
        pane = resolved.pane
        tab = resolved.tab
        target = state.target
        overlays = state.overlays
        generation = state.generation
        windowKey = state.windowKey
    }
}
