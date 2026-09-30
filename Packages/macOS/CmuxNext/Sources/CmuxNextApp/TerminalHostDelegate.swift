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
        openLink(url)
    }

    /// Cmd-click on a web URL: a browser tab in the focused pane on the
    /// default engine (`browser.defaultEngine`, Chromium). Other schemes, or
    /// no window, go to the system.
    func openLink(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https" else { return NSWorkspace.shared.open(url) }
        guard let pane = services?.windows.active?.focusedPane else {
            // No window: never hand a web link to the system, which may be
            // cmux itself as the default browser (a loop). It waits for one.
            services?.externalOpen.perform(.browserTab(url))
            return true
        }
        pane.newBrowserTab(url: url)
        return true
    }

    /// OSC 9, OSC 777 and OSC 99 from a program in this terminal: a daemon
    /// notification on this terminal's tab, tagged as a terminal source.
    /// (Only terminals the app shows reach here; see notifications.md.)
    func terminalSession(_ session: TerminalSession, didPostNotification title: String, body: String) {
        guard let services else { return }
        let surface = services.cache.tabKey(for: session).flatMap { services.locateTab($0)?.0.surface }
        let text = body
        let notifications = services.notifications
        notifications.expectCreate()
        services.daemon.send("notify") { connection in
            do {
                let id = try await connection.notify(title: title, body: text, surface: surface)
                await MainActor.run { notifications.record(id, source: .terminal) }
            } catch {
                await MainActor.run { notifications.createFailed() }
                throw error
            }
        }
    }

    /// The tab showing `session`, or nil (the focused pane) for a surface the
    /// cache does not own.
    private func target(of session: TerminalSession, in services: AppServices) -> ActionTargetRef? {
        services.cache.tabKey(for: session).map { ActionTargetRef(kind: .tab, id: $0) }
    }
}
