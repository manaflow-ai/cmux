public import Foundation

/// The page keys of a browser tab that take two letters (Vimium's `gg`, top of the page), among
/// the single letters the page left unhandled outside a text field (``BrowserPageKey``). A `g`
/// waits up to ``window`` for a second `g`; any other key, or a late one, starts over. The
/// key router keeps one per process: page keys arrive one at a time, from the page that has
/// the keyboard.
public nonisolated struct BrowserPageKeySequence: Sendable {
    /// What a page key does.
    public enum Step: Equatable, Sendable {
        /// The key runs the single-key action bound to it (`j`, `f`, Shift-G).
        case key(BrowserPageKey)
        /// The second `g` of `gg`: scroll to the top.
        case scrollToTop
        /// A first `g`: it waits for the next key.
        case held

        /// The action the step runs by id, or nil for a single key (its binding decides).
        public var action: String? { self == .scrollToTop ? BrowserPageScroll.top.actionID : nil }
    }

    /// How long a first `g` waits for the second.
    public static let window: Duration = .seconds(1)

    private var pendingG: ContinuousClock.Instant?

    public init() {}

    /// What `key`, typed at `now`, does.
    public mutating func feed(_ key: BrowserPageKey, at now: ContinuousClock.Instant) -> Step {
        guard key.character == "g", !key.shift else {
            pendingG = nil
            return .key(key)
        }
        if let first = pendingG, now - first <= Self.window {
            pendingG = nil
            return .scrollToTop
        }
        pendingG = now
        return .held
    }

    /// Forgets a waiting `g` (the page lost the keyboard, the setting went off).
    public mutating func reset() { pendingG = nil }
}
