/// Classifies an AppKit close-related action selector into how the detached
/// inspector-window close interceptor should treat it.
///
/// This captures only the pure selector-string -> intent classification. Whether a
/// concrete window can actually be resolved (and the fallback to the active / key /
/// main window) stays app-side, because that part reads live window state.
public enum WindowCloseActionIntent: Sendable, Equatable {
    /// The action always denotes a window close (`__close` / `performClose:`); intercept
    /// unconditionally.
    case interceptUnconditionally

    /// The action denotes a window close only when a target window can be resolved
    /// (`close` / `close:`); intercept only if the caller resolves a window.
    case interceptIfWindowResolvable

    /// The action is not a window-close action; do not intercept.
    case ignore

    /// Classifies a selector name (as produced by `NSStringFromSelector`) into a close-action
    /// intent.
    ///
    /// - Parameter selectorName: The selector string, e.g. `"performClose:"`.
    public init(selectorName: String) {
        switch selectorName {
        case "__close", "performClose:":
            self = .interceptUnconditionally
        case "close", "close:":
            self = .interceptIfWindowResolvable
        default:
            self = .ignore
        }
    }

    /// Whether window resolution may fall back to the active / key / main window for this
    /// action. Only the unconditional close selectors permit the fallback.
    public var allowsWindowFallback: Bool {
        self == .interceptUnconditionally
    }
}
