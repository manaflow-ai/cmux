import CmuxNextActions

/// The terminal-to-chat catalog rows (`terminal.fixLastCommand`, `terminal.sendLastOutputToChat`,
/// `terminal.sendSelectionToChat`) reached the pinned app FFI (#43840, re-pin #43935) before the
/// Swift that runs them (#38590). Until that lands, each row this build has no handler for is
/// a typed "unavailable" placeholder, left out of every context menu, so `HandlerCoverage`
/// holds and no menu offers a row that cannot run. A real bind replaces a placeholder, and one
/// made before this runs is kept.
enum TerminalToChatPlaceholders {
    static let ids: [ActionID] = ["terminal.fixLastCommand", "terminal.sendLastOutputToChat", "terminal.sendSelectionToChat"]

    static func bind(into registry: ActionRegistry) {
        let unbound = Set(registry.unboundActionIDs(in: [.terminal]))
        for id in ids where unbound.contains(id) {
            registry.bindUnavailable(id, reason: MiscHandlerStrings.terminalToChatUnavailable)
            ActionTargetVisibility.hide(id, in: registry) { _ in true }
        }
    }
}
