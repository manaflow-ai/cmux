import Foundation

/// The terminal-to-chat catalog rows (`terminal.fixLastCommand`, `terminal.sendLastOutputToChat`,
/// `terminal.sendSelectionToChat`) reached the pinned app FFI (#43840, re-pin #43935) before the
/// Swift that runs them (#38590). Until that lands, each row this build has no handler for is
/// a typed "unavailable" placeholder, left out of every context menu, so `HandlerCoverage`
/// holds and no menu offers a row that cannot run. A real bind replaces a placeholder, and one
/// made before this runs is kept.
public extension ActionRegistry {
    func bindTerminalToChatPlaceholders() {
        let ids: [ActionID] = ["terminal.fixLastCommand", "terminal.sendLastOutputToChat", "terminal.sendSelectionToChat"]
        let reason = String(localized: "terminalToChat.unavailable", defaultValue: "This build of cmux can't send terminal text to a chat yet.", bundle: .module)
        let unbound = Set(unboundActionIDs(in: [.terminal]))
        for id in ids where unbound.contains(id) {
            bindUnavailable(id, reason: reason)
            ActionTargetVisibility.hide(id, in: self) { _ in true }
        }
    }
}
