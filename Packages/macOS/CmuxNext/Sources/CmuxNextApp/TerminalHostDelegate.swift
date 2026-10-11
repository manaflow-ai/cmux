import AppKit
import CmuxNextActions
import CmuxNextTerminal

/// Handles terminal requests that need the app: Ghostty keybinds for splits,
/// tabs, and windows, the right-click menu, and links. OSC 9/777/99
/// notifications come from the daemon, which parses every terminal's output.
final class TerminalHostDelegate: TerminalSessionDelegate {
    weak var services: AppServices?

    /// A Ghostty keybind (`new_split:right`, `goto_split:left`, ...) runs the
    /// registry action every other entrypoint runs, targeted at this
    /// terminal's tab. Unmapped requests stay unhandled.
    func terminalSession(_ session: TerminalSession, perform action: TerminalHostAction) -> Bool {
        services?.keyRouter.trace?("terminal host action \(action) -> \(TerminalHostActionRoute.route(action)?.id.rawValue ?? "no route")")
        guard let services, let route = TerminalHostActionRoute.route(action) else { return false }
        let invocation = ActionInvocation(target: route.targetsTerminal ? target(of: session, in: services) : nil, arguments: route.arguments)
        // A refusal (no neighbor, one pane) is reported by the registry; the
        // key was still a binding, so it never reaches the shell.
        services.registry.perform(route.id, invocation: invocation)
        return true
    }

    /// The declared terminal context menu (`ContextMenuCatalog`), targeted at
    /// the right-clicked terminal's tab.
    func terminalSession(_ session: TerminalSession, contextMenuFor event: NSEvent) -> NSMenu? {
        guard let services else { return nil }
        let target = target(of: session, in: services)
        let menu = services.registry.makeContextMenu(for: .terminalSelection, target: target)
        // A right-click on a link Ghostty underlines offers the link rows
        // first (Open Link in New Tab, Copy Link, ...), then its browser
        // profiles (Open Link in Browser Profile ▸).
        let link = session.model.hoveredLink.flatMap(URL.init(string:))
        let linkRows = TerminalLinkMenu.items(for: link, target: target, registry: services.registry)
            + BrowserProfileLinkMenu.items(for: link, target: target, services: services)
        for (index, item) in linkRows.enumerated() {
            menu.insertItem(item, at: index)
        }
        return menu
    }

    /// Ghostty asks from inside its mouse-release handler with the
    /// terminal's renderer lock held (cx-7xss), so the open runs after the
    /// click returns: a browser tab or an app launch never stalls the
    /// terminal's output and drawing.
    func terminalSession(_ session: TerminalSession, open url: URL) -> Bool {
        // Cmd-Option-click asks which browser profile opens the link
        // (`browserProfile.openLink` without a profile: the palette lists
        // them); a plain Cmd-click uses the workspace's profile. Read now:
        // the click is the current event only during this call.
        let option = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        let tab = services.flatMap { target(of: session, in: $0) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let services, url.scheme == "http" || url.scheme == "https", option, services.browserProfiles.ordered.count > 1 {
                services.registry.perform("browserProfile.openLink", invocation: ActionInvocation(
                    target: tab, arguments: ["url": .string(url.absoluteString)]))
                return
            }
            openLink(url)
        }
        return true
    }

    /// Cmd-click on a web URL: a browser tab in the focused pane on the
    /// default engine (`browser.defaultEngine`, Chromium). Other schemes, or
    /// no window, go to the system without waiting for the app it launches.
    @discardableResult
    func openLink(_ url: URL) -> Bool {
        // A Chief subagent's link (`cmux chief` prints it as an OSC 8 hyperlink): this app's
        // link.open shows its workspace and tab, never another cmux build through the system.
        if let services, ChiefSubagentLinks.open(url, services: services) { return true }
        guard url.scheme == "http" || url.scheme == "https" else {
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        guard let pane = services?.windows.active?.focusedPane else {
            // No window: never hand a web link to the system, which may be
            // cmux itself as the default browser (a loop). It waits for one.
            services?.externalOpen.perform(.browserTab(url))
            return true
        }
        pane.newBrowserTab(url: url)
        return true
    }

    /// The tab showing `session`, or nil (the focused pane) for a surface the
    /// cache does not own.
    private func target(of session: TerminalSession, in services: AppServices) -> ActionTargetRef? {
        services.cache.tabKey(for: session).map { ActionTargetRef(kind: .tab, id: $0) }
    }
}
