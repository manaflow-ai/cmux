import Foundation

/// The floating pane catalog rows (`toggleFloatingPane`, `newFloatingPane`, `toggleQuickTerminal`)
/// reach the app before the App code that runs them (decision 2026-11-17: the catalog rows land
/// first). Until that code lands, each of them still unbound when the App has bound its handlers
/// is a typed "unavailable" placeholder, left out of every context menu, so the App's handler
/// coverage holds and no menu offers a row that cannot run. A real bind replaces a placeholder,
/// and one made before this runs is kept.
@MainActor
public struct FloatingPanePlaceholders {
    public init() {}
    public static let ids: [ActionID] = ["toggleFloatingPane", "newFloatingPane", "toggleQuickTerminal"]

    static var reason: String {
        String(localized: "floatingPanes.unavailable", defaultValue: "This build of cmux has no floating panes yet.", bundle: .localizedModule)
    }

    public static func bind(into registry: ActionRegistry) {
        let unbound = Set(registry.unboundActionIDs(in: [.pane]))
        for id in ids where unbound.contains(id) {
            registry.bindUnavailable(id, reason: reason)
            ActionTargetVisibility.hide(id, in: registry) { _ in true }
        }
    }
}
