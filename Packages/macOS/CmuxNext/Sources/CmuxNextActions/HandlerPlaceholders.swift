import Foundation

/// Each set of catalog rows that reached the app before the App code that runs them. The App
/// calls this one time, after it has bound its handlers: a row that is still unbound gets a typed
/// "unavailable" placeholder and stays out of every context menu.
@MainActor
public struct HandlerPlaceholders {
    public init() {}

    public static func bind(into registry: ActionRegistry) {
        TerminalToChatPlaceholders.bind(into: registry)
        FloatingPanePlaceholders.bind(into: registry)
    }
}
