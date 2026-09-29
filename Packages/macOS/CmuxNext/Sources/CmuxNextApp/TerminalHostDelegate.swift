import AppKit
import CmuxNextActions
import CmuxNextTerminal

/// Handles terminal requests that need the app: Ghostty keybinds for splits,
/// tabs, and windows, the right-click menu, links, and notifications.
final class TerminalHostDelegate: TerminalSessionDelegate {
    weak var services: AppServices?

    /// A Ghostty keybind (`new_split:right`, `goto_split:left`, ...) runs the
    /// registry action every other entrypoint runs, targeted at this
    /// terminal's tab. Unmapped requests stay unhandled.
    func terminalSession(_ session: TerminalSession, perform action: TerminalHostAction) -> Bool {
        guard let services, let route = TerminalHostActionRoute.route(action) else { return false }
        let invocation = ActionInvocation(target: target(of: session, in: services), arguments: route.arguments)
        // A refusal (no neighbor, one pane) is reported by the registry; the
        // key was still a binding, so it never reaches the shell.
        services.registry.perform(route.id, invocation: invocation)
        return true
    }

    /// The declared terminal context menu (`ContextMenuCatalog`), targeted at
    /// the right-clicked terminal's tab.
    func terminalSession(_ session: TerminalSession, contextMenuFor event: NSEvent) -> NSMenu? {
        guard let services else { return nil }
        return services.registry.makeContextMenu(for: .terminalSelection, target: target(of: session, in: services))
    }

    func terminalSession(_ session: TerminalSession, open url: URL) -> Bool {
        guard let pane = services?.windows.active?.focusedPane, url.scheme == "http" || url.scheme == "https" else {
            return NSWorkspace.shared.open(url)
        }
        pane.newBrowserTab(url: url)
        return true
    }

    func terminalSession(_ session: TerminalSession, didPostNotification title: String, body: String) {
        let text = body
        services?.daemon.send("notify") { connection in _ = try await connection.notify(title: title, body: text) }
    }

    /// The tab showing `session`, or nil (the focused pane) for a surface the
    /// cache does not own.
    private func target(of session: TerminalSession, in services: AppServices) -> ActionTargetRef? {
        services.cache.tabKey(for: session).map { ActionTargetRef(kind: .tab, id: $0) }
    }
}
