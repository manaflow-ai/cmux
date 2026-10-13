import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextSettings
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
        let request = linkRequest(session)
        Task { @MainActor [weak self] in self?.openWeb(url, request) }
        return true
    }

    /// Cmd-click on a link Ghostty found in the output (cx-do47): a URL, or a path as printed
    /// (``TerminalLinkResolver``). The path check reads the disk, off the main thread, after the
    /// click returns. A Markdown file opens the Markdown page, an image or PDF the preview, other
    /// files the code editor page and a folder Finder; a path that exists nowhere opens nothing.
    func terminalSession(_ session: TerminalSession, openLink text: String) -> Bool {
        let request = linkRequest(session)
        let cwd = session.model.workingDirectory ?? request.tab.flatMap { services?.cache.tabModel($0.id)?.cwd }
        Task { @MainActor [weak self] in
            let target = await Task.detached(priority: .userInitiated) { TerminalLinkResolver.resolve(text, cwd: cwd) }.value
            guard let self, let target else { return }
            switch target {
            case .url(let url):
                openWeb(url, request)
            case .file(let url, isDirectory: true):
                showInFinder(url)
            case .file(let url, isDirectory: false):
                #if DEBUG
                TerminalLinkRecorder.record("file:\(url.path)")
                #endif
                services?.viewers.openFile(url, in: nil, markdown: false)
            }
        }
        return true
    }

    /// The Cmd-hover underline goes only to links that open (cx-do47.1): a URL, a web host,
    /// or a path that names a file or folder (``TerminalLinkResolver``, the click's own rule).
    func terminalSessionLinkCheck(_ session: TerminalSession) -> TerminalLinkCheck? {
        let start = services.flatMap { services in target(of: session, in: services).flatMap { services.cache.tabModel($0.id)?.cwd } }
        return { text, cwd in TerminalLinkResolver.resolve(text, cwd: cwd ?? start) != nil }
    }

    /// What the click carried: Cmd-Option (`browserProfile.openLink` without a profile: the
    /// palette lists them; a plain Cmd-click uses the workspace's profile) and the clicked tab.
    /// Read now: the click is the current event only during the delegate call.
    private func linkRequest(_ session: TerminalSession) -> (option: Bool, tab: ActionTargetRef?) {
        (NSApp.currentEvent?.modifierFlags.contains(.option) == true, services.flatMap { target(of: session, in: $0) })
    }

    /// Cmd-Option asks for cmux (a profile), so only the external rules and host list route it out.
    private func openWeb(_ url: URL, _ request: (option: Bool, tab: ActionTargetRef?)) {
        if let services, url.scheme == "http" || url.scheme == "https", request.option, services.browserProfiles.ordered.count > 1,
           services.settings?.snapshot.terminalLinkRouting.opensInCmux(url, explicit: true) != false {
            services.registry.perform("browserProfile.openLink", invocation: ActionInvocation(
                target: request.tab, arguments: ["url": .string(url.absoluteString)]))
            return
        }
        openLink(url, explicit: request.option)
    }

    /// A folder opens in Finder; a package (an app, a bundle) shows selected in its folder, never launched.
    private func showInFinder(_ url: URL) {
        #if DEBUG
        if TerminalLinkRecorder.records { TerminalLinkRecorder.record("finder:\(url.path)"); return }
        #endif
        if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
            NSWorkspace.shared.revealInBackground([url])
        } else {
            NSWorkspace.shared.openInBackground(url)
        }
    }

    /// Cmd-click on a web URL: a browser tab in the focused pane on the
    /// default engine (`browser.defaultEngine`, Chromium). Other schemes, a web
    /// link classic's routing keys send out (`TerminalLinkRouting`), or no
    /// window, go to the system without waiting for the app it launches.
    @discardableResult
    func openLink(_ url: URL, explicit: Bool = false) -> Bool {
        // A Chief subagent's link (`cmux chief` prints it as an OSC 8 hyperlink): this app's
        // link.open shows its workspace and tab, never another cmux build through the system.
        if let services, ChiefSubagentLinks.open(url, services: services) { return true }
        guard url.scheme == "http" || url.scheme == "https",
              services?.settings?.snapshot.terminalLinkRouting.opensInCmux(url, explicit: explicit) != false else {
            #if DEBUG
            if TerminalLinkRecorder.records { TerminalLinkRecorder.record("system:\(url.absoluteString)"); return true }
            #endif
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        #if DEBUG
        TerminalLinkRecorder.record("browser:\(url.absoluteString)")
        #endif
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
