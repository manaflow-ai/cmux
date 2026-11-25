import Foundation

/// The terminal-to-chat catalog rows (`terminal.fixLastCommand`, `terminal.sendLastOutputToChat`,
/// `terminal.sendSelectionToChat`) reached the pinned app FFI (#43840, re-pin #43935) before the
/// App code that runs them (#38590). Until that lands, each of them still unbound when the App
/// has bound its handlers is a typed "unavailable" placeholder, left out of every context menu,
/// so the App's handler coverage holds and no menu offers a row that cannot run. A real bind
/// replaces a placeholder, and one made before this runs is kept.
@MainActor
public struct TerminalToChatPlaceholders {
    public init() {}
    public static let ids: [ActionID] = ["terminal.fixLastCommand", "terminal.sendLastOutputToChat", "terminal.sendSelectionToChat"]

    public static var reason: String {
        String(localized: "terminalToChat.unavailable", defaultValue: "This build of cmux can't send terminal text to a chat yet.", bundle: .localizedModule)
    }

    public static func bind(into registry: ActionRegistry) {
        let unbound = Set(registry.unboundActionIDs(in: [.terminal]))
        for id in ids where unbound.contains(id) {
            registry.bindUnavailable(id, reason: reason)
            ActionTargetVisibility.hide(id, in: registry) { _ in true }
        }
    }
}
