import Foundation

// Catalog rows that reach the App before their handlers: step A of an app FFI change
// (docs/ci/app-ffi-release.md) adds the row to the Rust catalog, and a same-tree build loads
// it at once, a pinned build after the re-pin. Until step B binds a real handler, each one
// binds as unavailable here, so the Debug launch check (`HandlerCoverage`) passes and every
// surface shows the row disabled with why. Step B's bind replaces the placeholder; then take
// its id off the list.
extension ActionRegistry {
    /// Rows awaiting their App handler: the terminal-to-chat actions (#43840, FFI step A of #38590).
    public static let awaitingHandlers: [ActionID] = [
        "terminal.fixLastCommand", "terminal.sendLastOutputToChat", "terminal.sendSelectionToChat",
    ]

    /// Binds each ``awaitingHandlers`` row this catalog has and nothing has bound yet as
    /// unavailable in this build, left out of every context menu (no menu offers a row that
    /// cannot run). A row the catalog lacks (an older FFI) binds nothing.
    @MainActor
    public func bindAwaitingHandlers() {
        for id in Self.awaitingHandlers where descriptor(for: id) != nil && !isBound(id) {
            bindUnavailable(id, reason: Self.awaitingHandlerReason)
            ActionTargetVisibility.hide(id, in: self) { _ in true }
        }
    }

    static var awaitingHandlerReason: String {
        String(localized: "action.unavailable.awaitingHandler",
               defaultValue: "This version of cmux can't run this action yet. Update cmux, then try again.",
               bundle: .module)
    }
}
