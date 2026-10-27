import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTerminal

/// Handles terminal requests that need the app: Ghostty keybinds for splits,
/// tabs, and windows, the right-click menu, and links. OSC 9/777/99
/// notifications come from the daemon, which parses every terminal's output.
final class TerminalHostDelegate: TerminalSessionDelegate {
    weak var services: AppServices? { didSet { if let services { Self.routeLinks(to: services) } } }

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

    /// The declared terminal context menu (`ContextMenuCatalog`), targeted at the right-clicked
    /// terminal's tab, led by the rows of the link or path Ghostty underlines (``linkMenu``).
    func terminalSession(_ session: TerminalSession, contextMenuFor event: NSEvent) -> NSMenu? {
        guard let services else { return nil }
        let target = target(of: session, in: services)
        let menu = services.registry.makeContextMenu(for: .terminalSelection, target: target)
        for (index, item) in linkMenu(session, services: services).items.enumerated() { menu.insertItem(item, at: index) }
        return menu
    }

    /// A link's rows (cx-ir3z4: Open in cmux Browser, ..., Copy Link; ``LinkMenu``), then its
    /// page rows (New Window, Split Right, ...) and browser profiles; a path's rows (Open, Open in
    /// Text Editor, Open With ▸, ...), resolved against the terminal's folder. `text` replaces the
    /// hovered link (`debug.terminal.links menu`).
    func linkMenu(_ session: TerminalSession, text: String? = nil, services: AppServices) -> (rows: [LinkMenuRow], items: [NSMenuItem]) {
        let target = target(of: session, in: services)
        let canOpenLocalFiles = allowsLocalFiles(session, services: services)
        // main-actor-ok: a right-click resolves one path (a few stat calls), as the click does.
        switch (text ?? session.model.hoveredLink).flatMap({ TerminalLinkResolver.resolve($0, cwd: cwd(of: session), allowsLocalFiles: canOpenLocalFiles) }) {
        case .url(let link)?:
            let menu = LinkMenu { [weak services] url in
                services?.registry.perform("browser.link.openInNewTab", invocation: ActionInvocation(target: target, arguments: ["url": .string(url.absoluteString)]))
            }
            let rows = menu.linkRows(for: link)
            let more = TerminalLinkMenu.items(for: link, target: target, registry: services.registry) + BrowserProfileLinkMenu.items(for: link, target: target, services: services)
            return (rows, menu.items(rows, link: link) + (rows.isEmpty ? [] : [.separator()]) + more)
        case .file(let file, let isDirectory)?:
            let menu = LinkMenu(), rows = menu.pathRows(for: file, isDirectory: isDirectory)
            return (rows, menu.items(rows, file: file) + [.separator()])
        case nil: return ([], [])
        }
    }

    /// Ghostty asks from inside its mouse-release handler with the
    /// terminal's renderer lock held (cx-7xss), so the open runs after the
    /// click returns: a browser tab or an app launch never stalls the
    /// terminal's output and drawing.
    func terminalSession(_ session: TerminalSession, open url: URL) -> Bool {
        guard case .url(let safeURL)? = TerminalLinkResolver.resolve(url.absoluteString, cwd: nil, allowsLocalFiles: false) else { return false }
        let request = linkRequest(session)
        Task { @MainActor [weak self] in self?.openWeb(safeURL, request) }
        return true
    }

    /// Cmd-click on a link Ghostty found in the output (cx-do47): a URL, or a path as printed
    /// (``TerminalLinkResolver``). The path check reads the disk, off the main thread, after the
    /// click returns. A Markdown file opens the Markdown page, an image or PDF the preview, other
    /// files the code editor page and a folder Finder; a path that exists nowhere opens nothing.
    func terminalSession(_ session: TerminalSession, openLink text: String) -> Bool {
        let request = linkRequest(session), cwd = cwd(of: session)
        if let services, let machine = fileMachine(session, services: services) {
            // task-owner: one Cmd-click's lookup on the terminal's machine; ends when its file opens or nothing does
            Task { @MainActor [weak self] in await self?.openMachineLink(text, cwd: cwd, on: machine, request) }
            return true
        }
        let canOpenLocalFiles = services.map { self.allowsLocalFiles(session, services: $0) } ?? false
        Task { @MainActor [weak self] in
            let target = await Task.detached(priority: .userInitiated) {
                TerminalLinkResolver.resolve(text, cwd: cwd, allowsLocalFiles: canOpenLocalFiles)
            }.value
            switch target {
            case .url(let url)?: self?.openWeb(url, request)
            case .file(let url, isDirectory: true)?: LinkRouter.shared.showInFinder(url)
            case .file(let url, isDirectory: false)?:
                // `src/app.ts:3:5` opens the editor at line 3, column 5.
                let position = TerminalLinkResolver.location(text).map { FilePosition(line: $0.line, column: $0.column ?? 1) }
                LinkRouter.shared.record("file:\(url.path)" + (position.map { ":\($0.pageText)" } ?? ""))
                guard let services = self?.services else { return }
                services.linkOpener.openFile(url, from: services.linkOpener.source(tab: request.tab?.id), at: position)
            case nil: break
            }
        }
        return true
    }

    /// A Cmd-click in a terminal of another machine (#25581, a Cloud workspace): the first path the
    /// text may name (``TerminalLinkResolver/remoteCandidates(_:cwd:)``) that the machine says is a
    /// file opens in its page, read from that machine; else a web link opens as anywhere. Nothing of
    /// this Mac's disk is read, and a folder opens nothing (Finder shows this Mac).
    private func openMachineLink(_ text: String, cwd: String?, on machine: DaemonService,
                                 _ request: (option: Bool, other: Bool, tab: ActionTargetRef?)) async {
        guard let services else { return }
        let files = services.agentGit.link(for: machine)
        for path in TerminalLinkResolver.remoteCandidates(text, cwd: cwd) {
            guard let stat = try? await files.stat(path) else { continue }
            guard stat.kind == "file" || stat.kind == "symlink" else { return }
            let position = TerminalLinkResolver.location(text).map { FilePosition(line: $0.line, column: $0.column ?? 1) }
            services.linkOpener.openFile(URL(fileURLWithPath: path), on: machine, from: services.linkOpener.source(tab: request.tab?.id),
                                         at: position)
            return
        }
        if case .url(let url)? = TerminalLinkResolver.resolve(text, cwd: nil, allowsLocalFiles: false) { openWeb(url, request) }
    }

    /// The daemon of the machine whose files `session`'s output names, when that is not this Mac: a
    /// terminal of a Cloud workspace (the machine's daemon serves its files, `fs-v1`). Nil for this
    /// Mac's terminals, a remote-terminal projection, and machines that serve no files.
    private func fileMachine(_ session: TerminalSession, services: AppServices) -> DaemonService? {
        guard let ref = target(of: session, in: services), let tab = services.cache.tabModel(ref.id),
              tab.kind != .remoteTerminal else { return nil }
        let daemon = services.machines.daemon(forTab: tab)
        return daemon.isLocal || daemon.identity?.supports(FileSystemReadRequest.requiredCapability ?? "") != true ? nil : daemon
    }

    /// The terminal's folder, else its tab's: where a relative path in its output starts.
    private func cwd(of session: TerminalSession) -> String? {
        session.model.workingDirectory ?? services.flatMap { services in target(of: session, in: services).flatMap { services.cache.tabModel($0.id)?.cwd } }
    }

    /// The Cmd-hover underline goes only to links that open (cx-do47.1): a URL, a web host,
    /// or a path that names a file or folder (``TerminalLinkResolver``, the click's own rule).
    func terminalSessionLinkCheck(_ session: TerminalSession) -> TerminalLinkCheck? {
        let start = services.flatMap { services in target(of: session, in: services).flatMap { services.cache.tabModel($0.id)?.cwd } }
        let canOpenLocalFiles = services.map { self.allowsLocalFiles(session, services: $0) } ?? false
        // Another machine's paths cannot be checked from here while the pointer moves: a path the
        // text may name there is underlined, and the click asks the machine (``openMachineLink``).
        if let services, fileMachine(session, services: services) != nil {
            return { text, cwd in
                !TerminalLinkResolver.remoteCandidates(text, cwd: cwd ?? start).isEmpty
                    || TerminalLinkResolver.resolve(text, cwd: nil, allowsLocalFiles: false) != nil
            }
        }
        return { text, cwd in TerminalLinkResolver.resolve(text, cwd: cwd ?? start, allowsLocalFiles: canOpenLocalFiles) != nil }
    }

    /// A local path belongs to this Mac only for a local PTY tab, never a remote-terminal projection.
    private func allowsLocalFiles(_ session: TerminalSession, services: AppServices) -> Bool {
        guard let ref = target(of: session, in: services), let tab = services.cache.tabModel(ref.id),
              tab.kind != .remoteTerminal else { return false }
        return services.machines.daemon(forTab: tab).isLocal
    }

    /// What the click carried: Cmd-Option (`browserProfile.openLink` without a profile: the
    /// palette lists them; a plain Cmd-click uses the workspace's profile), Shift-Command (the
    /// browser the link setting does not pick) and the clicked tab. Read now: the click is the
    /// current event only during the delegate call.
    private func linkRequest(_ session: TerminalSession) -> (option: Bool, other: Bool, tab: ActionTargetRef?) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        return (flags.contains(.option), LinkRouter.isOtherTarget(flags), services.flatMap { target(of: session, in: $0) })
    }

    /// Cmd-Option asks for cmux (a profile), so only the external rules and host list route it out;
    /// every other link goes through the shared rule (``LinkRouter``).
    private func openWeb(_ url: URL, _ request: (option: Bool, other: Bool, tab: ActionTargetRef?)) {
        if let services, url.scheme == "http" || url.scheme == "https", request.option, services.browserProfiles.ordered.count > 1,
           LinkRouter.shared.target(for: url, explicit: true) == .cmuxBrowser {
            services.registry.perform("browserProfile.openLink", invocation: ActionInvocation(
                target: request.tab, arguments: ["url": .string(url.absoluteString)]))
            return
        }
        LinkRouter.shared.open(url, otherTarget: request.other, explicit: request.option, source: request.tab?.id)
    }

    /// Every surface's links go through ``LinkRouter`` (cx-ir3z4), wired here once: a Chief
    /// subagent's link runs `link.open`; a cmux link opens a browser tab on the default engine
    /// where ``LinkOpener`` places it (the pane right of the clicked tab's pane, or a new split). With no window it waits for one, never the system, which may be cmux
    /// itself as the default browser (a loop).
    private static func routeLinks(to services: AppServices) {
        let router = LinkRouter.shared
        router.routing = { [weak services] in services?.settings?.snapshot.linkRouting ?? .fallback }
        router.textEditor = { [weak services] in services?.settings?.snapshot.textEditor.application ?? "" }
        router.appLink = { [weak services] url in services.map { CmuxAppLinks.open(url, services: $0) } ?? false }
        // A click in a chat or page view opens beside the pane showing it (not the focused pane).
        router.sourceTab = { [weak services] view in services?.linkOpener.source(containing: view)?.currentTabKey }
        router.openInCmux = { [weak services] url, background, source in
            guard let services else { return }
            // Beside the source pane (`layout.linkPlacement`, LinkOpener), never in its place.
            guard let pane = services.linkOpener.source(tab: source) else { services.externalOpen.perform(.browserTab(url)); return }
            // A link clicked in an agent chat (its chips) reuses the page's tab on the right, as its card's Open does.
            let fromChat = source.map(services.agentTabs.isAgentTab) ?? false
            services.linkOpener.openWeb(url, from: pane, background: background, reusesTab: fromChat)
        }
    }

    /// The tab showing `session`, or nil (the focused pane) for a surface the
    /// cache does not own.
    private func target(of session: TerminalSession, in services: AppServices) -> ActionTargetRef? {
        services.cache.tabKey(for: session).map { ActionTargetRef(kind: .tab, id: $0) }
    }
}
