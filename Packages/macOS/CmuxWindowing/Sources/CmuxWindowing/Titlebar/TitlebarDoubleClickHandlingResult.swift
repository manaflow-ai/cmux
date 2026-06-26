public import AppKit

/// The outcome of handling a titlebar double-click for a given
/// ``TitlebarDoubleClickBehavior``.
public enum TitlebarDoubleClickHandlingResult: Equatable {
    case ignored
    case suppressed
    case performed(StandardTitlebarDoubleClickAction)

    /// Whether the event was consumed; true for anything other than ``ignored``.
    public var consumesEvent: Bool {
        self != .ignored
    }

    /// Applies `behavior` to `window`'s double-click and reports the result.
    /// For ``TitlebarDoubleClickBehavior/standardAction`` it runs the standard
    /// macOS titlebar action, yielding ``ignored`` when there is no window.
    @discardableResult
    @MainActor
    public static func handle(
        window: NSWindow?,
        behavior: TitlebarDoubleClickBehavior
    ) -> TitlebarDoubleClickHandlingResult {
        switch behavior {
        case .standardAction:
            guard let action = StandardTitlebarDoubleClickAction.performStandard(window: window) else {
                return .ignored
            }
            return .performed(action)
        case .suppress:
            return .suppressed
        }
    }
}
