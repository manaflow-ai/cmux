public import CmuxNextFocus
import Foundation

/// One record of the input journal (plans/cmux-next/input-spec.md section 3):
/// an input event, a focus or attach transition, or a diagnostic marker,
/// with a monotonic timestamp and the cmux window it concerns.
///
/// Privacy: key records carry the key code and modifier classes only.
/// `characters` is filled only when the user opted in
/// (`CMUX_NEXT_INPUT_JOURNAL_CHARACTERS=1`). Attach records carry byte
/// counts, never bytes. Ids are daemon pane, tab and surface ids.
public nonisolated struct InputJournalEntry: Hashable, Sendable, Codable {
    /// Strictly increasing per process; gaps mean the ring overwrote entries.
    public var seq: UInt64
    /// `CLOCK_UPTIME_RAW` nanoseconds at capture.
    public var uptimeNanos: UInt64
    /// `WindowState.id` of the cmux window (a Chromium page window counts as
    /// its parent); nil for panels and app-wide records.
    public var window: String?
    public var kind: Kind

    public init(seq: UInt64, uptimeNanos: UInt64, window: String? = nil, kind: Kind) {
        self.seq = seq
        self.uptimeNanos = uptimeNanos
        self.window = window
        self.kind = kind
    }

    public enum Kind: Hashable, Sendable, Codable {
        case key(Key)
        case mouse(Mouse)
        case windowKey(Bool)
        case appActive(Bool)
        /// A focus state machine input and the state it produced.
        case focus(FocusEvent, after: FocusDigest)
        /// The window's full focus state (the machine's JSON), so replay can
        /// start mid-ring.
        case focusCheckpoint(FocusCheckpoint)
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
        /// A tab content lifecycle step (show, hide, page window shown or
        /// hidden, a late completion dropped), plans/cmux-next/tab-lifecycle.md.
        case content(tab: String, event: String)
        /// No-activate mode gave the keyboard back (NoActivateKeyboardGuard):
        /// what took it, why it was not the user's, and the app it went to.
        case keyboardGivenBack(trigger: String, cause: String, restoredTo: Int32?)
    }

    public enum KeyPhase: String, Hashable, Sendable, Codable {
        case down, up, flags
    }

    /// What kind of key it was, without saying which one.
    public enum KeyClass: String, Hashable, Sendable, Codable {
        case letter, digit, punctuation, space
        /// Return, Tab, Escape, Delete, arrows, function keys.
        case named
        /// A modifier key (flags changed).
        case modifier
        /// Any other printable input (non-Latin letters, symbols, IME).
        case other

        /// Keys whose code is text, and so is never journaled for typing.
        public var isText: Bool {
            switch self {
            case .letter, .digit, .punctuation, .space, .other: true
            case .named, .modifier: false
            }
        }
    }

    /// Privacy (input-spec.md section 3): typed text never reaches the
    /// journal. Typing (a text key without Command or Control) records only
    /// its class and modifiers; `keyCode` is kept for shortcuts, named keys
    /// and modifiers, whose code is not text. `characters` only with the
    /// debug-build opt-in.
    public struct Key: Hashable, Sendable, Codable {
        public var phase: KeyPhase
        public var keyClass: KeyClass
        public var keyCode: UInt16?
        public var modifiers: ModifierClasses
        public var isRepeat: Bool
        public var characters: String?

        /// The record for a key event; `characters` is what it typed, used
        /// only to classify unless `recordsCharacters`.
        public init(phase: KeyPhase, keyCode: UInt16, characters: String?, modifiers: ModifierClasses, isRepeat: Bool,
             recordsCharacters: Bool) {
            let keyClass: KeyClass = phase == .flags ? .modifier : Self.classify(characters)
            let shortcut = !modifiers.isDisjoint(with: [.command, .control])
            self.phase = phase
            self.keyClass = keyClass
            self.keyCode = recordsCharacters || shortcut || !keyClass.isText ? keyCode : nil
            self.modifiers = modifiers
            self.isRepeat = isRepeat
            self.characters = recordsCharacters && phase != .flags ? characters : nil
        }

        public static func classify(_ characters: String?) -> KeyClass {
            guard let scalar = characters?.unicodeScalars.first else { return .named }
            // AppKit's function-key range (arrows, F-keys, Home, End) and
            // controls (Return, Tab, Escape, Delete).
            if (0xF700...0xF8FF).contains(scalar.value) || CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0x7F {
                return .named
            }
            if scalar == " " { return .space }
            guard scalar.isASCII else { return .other }
            if CharacterSet.decimalDigits.contains(scalar) { return .digit }
            if CharacterSet.letters.contains(scalar) { return .letter }
            return .punctuation
        }
    }

    /// Device-independent modifier classes (no characters, no key identity).
    public struct ModifierClasses: OptionSet, Hashable, Sendable, Codable {
        public var rawValue: UInt8
        public static let command = ModifierClasses(rawValue: 1 << 0)
        public static let shift = ModifierClasses(rawValue: 1 << 1)
        public static let option = ModifierClasses(rawValue: 1 << 2)
        public static let control = ModifierClasses(rawValue: 1 << 3)
        public static let function = ModifierClasses(rawValue: 1 << 4)
        public static let capsLock = ModifierClasses(rawValue: 1 << 5)

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public var names: [String] {
            [(Self.command, "cmd"), (.shift, "shift"), (.option, "option"), (.control, "ctrl"), (.function, "fn"), (.capsLock, "caps")]
                .compactMap { contains($0.0) ? $0.1 : nil }
        }
    }

    public enum MousePhase: String, Hashable, Sendable, Codable {
        case down, up, drag, scroll
    }

    public struct Mouse: Hashable, Sendable, Codable {
        public var phase: MousePhase
        /// 0 left, 1 right, 2 other.
        public var button: Int
        /// Window-local points from the top-left of the cmux window (the
        /// coordinates `debug.mouse` takes). For a drag or scroll run, the
        /// last location.
        public var x: Double
        public var y: Double
        public var clickCount: Int
        public var modifiers: ModifierClasses
        /// Consecutive drag or scroll events merged into this entry.
        public var count: Int = 1
        /// Summed scroll deltas.
        public var dx: Double = 0
        public var dy: Double = 0

        public init(phase: MousePhase, button: Int, x: Double, y: Double, clickCount: Int, modifiers: ModifierClasses,
                    count: Int = 1, dx: Double = 0, dy: Double = 0) {
            self.phase = phase
            self.button = button
            self.x = x
            self.y = y
            self.clickCount = clickCount
            self.modifiers = modifiers
            self.count = count
            self.dx = dx
            self.dy = dy
        }
    }

    public struct Attach: Hashable, Sendable, Codable {
        public var surface: String
        /// `start`, `opened`, `openFailed`, `replay`, `input`, `resize:CxR`, `grid:CxR`, `focused`,
        /// `visible`, `hidden`, `ended:<reason>`, `close`.
        public var event: String
        /// Link identity (per process), when the event names one.
        public var link: Int?
        public var attempt: Int?
        /// Input bytes (never the bytes themselves).
        public var bytes: Int = 0
        /// Machine phase after the event.
        public var phase: String
        public var droppedBytes: Int = 0

        public init(surface: String, event: String, link: Int? = nil, attempt: Int? = nil, bytes: Int = 0, phase: String,
                    droppedBytes: Int = 0) {
            self.surface = surface
            self.event = event
            self.link = link
            self.attempt = attempt
            self.bytes = bytes
            self.phase = phase
            self.droppedBytes = droppedBytes
        }
    }
}

/// What `debug.focus` and replay compare after each focus transition.
public nonisolated struct FocusDigest: Hashable, Sendable, Codable {
    public var resolved: String
    public var pane: String?
    public var tab: String?
    public var target: FocusState.Target
    public var overlays: [FocusState.Overlay]
    public var generation: UInt64
    public var windowKey: Bool

    public init(_ state: FocusState) {
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
