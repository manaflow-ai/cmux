import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDesign
import enum CmuxNextDaemon.DaemonError
import typealias CmuxNextDaemon.SurfaceID
import class CmuxNextDaemon.TabModel
import CmuxNextDaemonService
import CmuxNextDiff
import CmuxNextIcons
import CmuxNextPages
import CmuxNextSettings

extension InternalPageID {
    /// The diff viewer (diff-host.md Q4: a pane tab in the workspace).
    nonisolated static let diff = InternalPageID(rawValue: "diff")
}

/// Why ``DiffPageService/open(folder:source:in:focus:)`` opened nothing.
nonisolated enum DiffOpenFailure: Error, Sendable, Equatable {
    /// The folder is in no git repository (or the session host cannot say).
    case notRepository
    /// The folder's machine did not answer (#25581): the reason, naming the machine.
    case unavailable(String)
}

/// Owns the diff viewer tabs: `cmux-page://cmux.diff/` pages, one per tab, each
/// with its own provider, grant and patch source (``DiffPageProvider``,
/// ``DiffSessionGrant``, ``DiffPatchSource``).
///
/// Entry point: ``open(folder:source:in:focus:)`` opens the tab of a folder's
/// repository (R89's open actions with the focused pane's folder, the cmux
/// picker with a chosen one). A folder in no repository throws, and the open
/// actions show the picker; no empty diff tab opens. A tab whose repository
/// is not ready shows the page's empty state, which lists recents, asks for a
/// folder (``DiffFolderChoosing``, the cmux picker) or takes a dropped one.
/// Every open records the repository in ``DiffRecents``.
final class DiffPageService: InternalPageProvider {
    private struct Tab {
        var repository: DiffRepository?
        var source: DiffOpenSource
        /// The chat turn its Last turn scope shows (D2), from the chat that opened it.
        var turn: DiffTurn?
        /// The chat's session host. A remote tab must retain this link for every page read.
        var gitLink: AgentPaneGitLink?
        var runtime: DiffPageRuntime?
        /// The daemon of the Cloud workspace's machine the repository is on (#25581); nil for this
        /// Mac and for a remote chat's tab. Its file opens in that machine's file tab.
        var machine: DaemonService?
        var page: PageWebView?
        var provider: DiffPageProvider?
        var host: DiffTabHost?
        /// The reopen on a card's turn in flight (``retarget(_:to:source:)``), one at a time.
        var reopen: Task<Void, Never>?
        var creating = false
        var surface: SurfaceID?
        var completions: [Completion] = []
    }

    private struct Completion {
        var created: (@MainActor (SurfaceID) -> Void)?
        var failed: (@MainActor ((any Error)?) -> Void)?
    }

    // crash-allow: AppServices owns this service for the app's whole life (ViewerService's lazy page services), so it outlives it.
    private unowned let services: AppServices
    /// Made on the first tab (tests pass their own).
    private lazy var runtime = DiffPageRuntime(git: services.agentGit.local)
    private lazy var recentsStore = DiffRecents(url: DiffRecents.standardURL(launch: services.environment.launch))
    /// Prefs (`diff.*` settings) and viewed marks (next to the recents), shared by every tab.
    private lazy var stores = DiffPageStores(prefs: SettingsDiffPrefs { [weak services] in services?.settings },
                                             viewed: DiffViewedFiles(url: DiffViewedFiles.standardURL(recents: recentsStore.url)))
    /// The diff page draws at the display's full rate (120 Hz), as the agent pane does, not
    /// WebKit's default nearest 60 fps.
    static let engineOptions = PageEngineOptions(fullFrameRate: true)
    /// Every tab's Stage, Commit and Push (cx-ueuc8), through this Mac's agent git link.
    private lazy var diffGit: any DiffGitRunning = DiffAgentGit(link: services.agentGit.local)
    /// The folder picker of `cmux.diff.chooseFolder`.
    var chooser: any DiffFolderChoosing = OpenPanelFolderChooser()
    private var tabs: [String: Tab] = [:]
    /// Teardowns still closing sessions (tests wait on them).
    private(set) var closing: [Task<Void, Never>] = []

    /// Remote chats get a runtime whose status reads and grants are owned by their daemon.
    /// Local tabs keep the shared sidecar runtime.
    private func runtime(for link: AgentPaneGitLink) -> DiffPageRuntime {
        link.isLocal ? runtime : DiffPageRuntime(git: link)
    }

    /// A missing link for a remote chat is a routing refusal, never permission to read the same
    /// path through this Mac's checkout.
    func gitLink(for tab: TabModel?) -> AgentPaneGitLink? {
        guard let tab, let record = tab.agentSession else { return services.agentGit.local }
        guard services.locateTab(model: tab) != nil else { return nil }
        guard AgentPaneHostKind(record, localHost: services.agentTabs.localHost,
                                chiefHost: services.agentTabs.chiefHost,
                                listedHere: services.machines.daemon(forTab: tab).isLocal) == .remote else {
            return services.agentGit.local
        }
        guard let daemon = try? services.machines.agentDaemon(forTab: tab) else { return nil }
        return services.agentGit.link(for: daemon)
    }

    init(services: AppServices, runtime: DiffPageRuntime? = nil, recents: DiffRecents? = nil, stores: DiffPageStores? = nil) {
        self.services = services
        if let runtime { self.runtime = runtime }
        if let recents { recentsStore = recents }
        if let stores { self.stores = stores }
    }

    var page: InternalPageID { .diff }
    var title: String { DiffPageStrings.tabTitle }
    var symbol: String { "plusminus" }
    var icon: IconName? { .diffFile }
    var recents: DiffRecents { recentsStore }

    func title(for key: String) -> String { tabs[key]?.repository?.name ?? title }

    /// Opens a diff tab for the repository `folder` is in, comparing `source`
    /// first, after `pane`'s selected tab, or selects the tab of `pane`'s
    /// window that already shows it. A user run (`focus`) selects and focuses
    /// it. Throws ``DiffOpenFailure/notRepository`` and opens nothing when the
    /// folder is in no repository.
    /// A chat's open names its `turn` (D1, D2): the tab offers it as Last turn, and with `source`
    /// `.turn` (an edited-files card) opens on it, at its file.
    @discardableResult
    func open(folder: URL, source: DiffOpenSource = .default, turn: DiffTurn? = nil, in pane: PaneController,
              focus: Bool, on machine: DaemonService? = nil,
              created: (@MainActor (SurfaceID) -> Void)? = nil,
              failed: (@MainActor ((any Error)?) -> Void)? = nil) async throws(DiffOpenFailure) -> String {
        let paneLink = machine.flatMap { $0.isLocal ? nil : services.agentGit.link(for: $0) }
        if let machine, let link = paneLink, readsOnPaneMachine(link, selected: pane.selectedTab) {
            // A Cloud workspace's folder (#25581): that machine's session host reads it.
            let repository: DiffRepository?
            do {
                repository = try await DiffPageRuntime.repository(at: folder, git: DiffAgentGit(link: link))
            } catch {
                guard error == .notConnected || error == .timedOut else { throw .notRepository }
                throw .unavailable(DiffPageStrings.machineOffline(machineName(machine)))
            }
            guard let repository else { throw .notRepository }
            return open(repository: repository, source: source, turn: turn, gitLink: link, runtime: runtime(for: link),
                        in: pane, focus: focus, on: machine, created: created, failed: failed)
        }
        guard let link = gitLink(for: pane.selectedTab) else { throw .notRepository }
        let tabRuntime = runtime(for: link)
        guard let repository = await tabRuntime.repository(at: folder) else { throw .notRepository }
        return open(repository: repository, source: source, turn: turn, gitLink: link, runtime: tabRuntime,
                    in: pane, focus: focus, created: created, failed: failed)
    }

    /// Whether an open from a pane on the machine of `link` reads there. A selected chat's diff
    /// reads where its session runs (``gitLink(for:)``, #26113), so it takes the pane's machine only
    /// when that is the same one: a chat this Mac runs, or one refused, never reads the pane's VM.
    func readsOnPaneMachine(_ link: AgentPaneGitLink, selected: TabModel?) -> Bool {
        guard let selected, selected.agentSession != nil else { return true }
        return gitLink(for: selected) === link
    }

    private func machineName(_ machine: DaemonService) -> String {
        services.machines.machineName(machine.machineID) ?? machine.machineID
    }

    /// ``open(folder:source:turn:in:focus:)`` once the repository is known. One tab per
    /// repository and scope in the window, as before; a turn open (``DiffTabReuse``) takes the
    /// window's tab of the repository in any scope and switches it to the turn.
    @discardableResult
    func open(repository: DiffRepository, source: DiffOpenSource = .default, turn: DiffTurn? = nil,
              gitLink: AgentPaneGitLink? = nil, runtime: DiffPageRuntime? = nil, in pane: PaneController,
              focus: Bool, on machine: DaemonService? = nil, created: (@MainActor (SurfaceID) -> Void)? = nil,
              failed: (@MainActor ((any Error)?) -> Void)? = nil) -> String {
        let link = gitLink ?? services.agentGit.local
        // The recents are repositories of this Mac.
        if link.isLocal { record(repository, source: source) }
        let before = Set(tabs.keys)
        let key = show(in: pane, focus: focus,
                       Tab(repository: repository, source: source, turn: turn, gitLink: link,
                           runtime: runtime, machine: machine), created: created, failed: failed) {
            DiffTabReuse.reuses(root: $0.repository?.root, source: $0.source, for: repository.root, source)
                && $0.gitLink === link && $0.machine?.machineID == machine?.machineID
        }
        // A tab already there takes the chat's turn: a card's reloads it on the turn and file; a
        // header's newer turn is what its Last turn shows from then on, with no reload.
        guard before.contains(key), let shown = tabs[key] else { return key }
        switch DiffTabReuse.change(shownTurn: shown.turn, source, turn) {
        case .keep: break
        case .newTurn:
            tabs[key]?.turn = turn
        case .reload:
            tabs[key]?.source = .turn
            tabs[key]?.turn = turn
            retarget(key, to: repository)
        }
        return key
    }

    /// Shows a card's turn in tab `key`: a new grant, then the page loads again. Reopens run one
    /// at a time, the newest last, so two never retire the same grant. A tab whose view is not
    /// made yet reads the turn when it is.
    private func retarget(_ key: String, to repository: DiffRepository) {
        guard let provider = tabs[key]?.provider, let page = tabs[key]?.page else { return }
        let previous = tabs[key]?.reopen
        previous?.cancel()
        // task-owner: one reopen of this tab's repository, after the one before it; ends when the page reloads or a newer card takes over
        tabs[key]?.reopen = Task {
            await previous?.value
            guard !Task.isCancelled,
                  (try? await provider.open(folder: URL(fileURLWithPath: repository.root, isDirectory: true), source: .turn)) != nil,
                  !Task.isCancelled else { return }
            page.reload()
        }
    }

    /// The turn tab `key` shows in `repository` now.
    fileprivate func turn(for key: String, in repository: String) -> DiffTurn? {
        tabs[key].flatMap { $0.repository?.root == repository ? $0.turn : nil }
    }

    /// The tab opens as a store tab where the pane's daemon holds page tabs
    /// (page-tabs-v1), so it moves between panes and columns like any daemon
    /// tab (`created` gets its surface); else as an app-only tab.
    private func show(in pane: PaneController, focus: Bool, _ tab: Tab, created: (@MainActor (SurfaceID) -> Void)?,
                      failed: (@MainActor ((any Error)?) -> Void)?, matching: (Tab) -> Bool) -> String {
        let window = services.windowController(showing: pane)
        for candidate in window?.content?.panes.values.map({ $0 }) ?? [pane] {
            let keys = services.pages.tabIDs(in: candidate.paneKey) + candidate.pane.tabs.compactMap { services.pages.storeKey(of: $0.id) }
            if let shown = keys.first(where: { key in
                guard let tab = tabs[key], matching(tab) else { return false }
                // Promote an app-only fallback to a movable tab for a beside open.
                return created == nil || tab.creating || tab.surface != nil
            }) {
                if focus { reveal(shown, in: candidate) }
                if tabs[shown]?.creating == true {
                    tabs[shown]?.completions.append(Completion(created: created, failed: failed))
                } else if let surface = tabs[shown]?.surface { created?(surface) }
                return shown
            }
        }
        let key = LocalPageTab.makeKey(.diff)
        var tab = tab
        tab.creating = true
        tab.completions = [Completion(created: created, failed: failed)]
        tabs[key] = tab
        let requiresSurface = created != nil
        if let window,
           services.pages.openStoreTab(.diff, in: pane, window: window, focus: focus, key: key, created: { [weak self] surface in
               guard let self else { return }
               let completions = self.tabs[key]?.completions ?? []
               self.tabs[key]?.creating = false
               self.tabs[key]?.surface = surface
               self.tabs[key]?.completions = []
               for completion in completions { completion.created?(surface) }
           }, failed: { [weak self] error in
               guard let self else { return }
               let completions = self.tabs[key]?.completions ?? []
               self.tabs[key]?.creating = false
               self.tabs[key]?.completions = []
               for completion in completions { completion.failed?(error) }
           }, requiresSurface: requiresSurface) != nil { return key }
        tabs[key]?.creating = false
        if requiresSurface {
            if window == nil { failed?(DaemonError.notConnected) }
            tabClosed(key)
            return key
        }
        services.pages.open(.diff, in: pane.paneKey, of: pane.daemon.store, after: pane.stripModel.selectedID?.rawValue,
                            window: window, key: key)
        pane.apply(pane.snapshot())
        if focus { reveal(key, in: pane) }
        return key
    }

    private func reveal(_ key: String, in pane: PaneController) {
        pane.select(services.pages.stripID(showing: key, in: pane) ?? StripTabID(key))
        pane.focusContent()
    }

    private func record(_ repository: DiffRepository, source: DiffOpenSource) {
        let recents = recentsStore
        // task-owner: one ordered append to the recents file; DiffRecents chains its writes
        Task { await recents.record(repository, source: source) }
    }

    /// The repository root the tab opened on (page-tab-route-v1).
    func route(for key: String) -> String? {
        tabs[key]?.gitLink?.isLocal == false ? nil : tabs[key]?.repository?.root
    }

    /// A store tab came back on repository root `route` (Reopen Closed,
    /// relaunch): it shows that root against its default base.
    func restore(_ route: String, for key: String) {
        guard tabs[key] == nil, route.hasPrefix("/") else { return }
        tabs[key] = Tab(repository: DiffRepository(root: route, branch: nil, base: nil), source: .default,
                         gitLink: services.agentGit.local, runtime: runtime)
    }

    /// The diff page of `key`, nil for any other tab or before its view exists.
    func pageView(_ key: String) -> PageWebView? { tabs[key]?.page }

    func provider(_ key: String) -> DiffPageProvider? { tabs[key]?.provider }

    // MARK: Tab host

    fileprivate func repository(at folder: URL, for key: String) async -> DiffRepository? {
        await (tabs[key]?.runtime ?? runtime).repository(at: folder)
    }

    /// The tab's turn goes with a grant of its own repository only.
    fileprivate func prepare(_ repository: DiffRepository, source: DiffOpenSource, for key: String) -> Task<DiffTabReady, any Error> {
        let turn = turn(for: key, in: repository.root)
        return (tabs[key]?.runtime ?? runtime).prepare(repository: repository,
                                                       source: turn == nil && source == .turn ? .default : source, turn: turn)
    }

    fileprivate func chooseFolder(start: URL?, for key: String) async -> URL? {
        var start = start
        if start == nil, let newest = await recentsStore.list().first {
            start = URL(fileURLWithPath: newest.path).deletingLastPathComponent()
        }
        return await chooser.chooseFolder(start: start, anchor: tabs[key]?.page?.window)
    }

    /// The tab `key` now shows `repository`: record it and retitle the tab.
    fileprivate func opened(_ repository: DiffRepository, source: DiffOpenSource, in key: String) {
        // The recents are repositories of this Mac.
        if tabs[key]?.gitLink?.isLocal != false { record(repository, source: source) }
        if tabs[key]?.repository?.root != repository.root { tabs[key]?.turn = nil }
        tabs[key]?.repository = repository
        tabs[key]?.source = source
        if let pane = services.paneController(showingTab: key) { pane.apply(pane.snapshot()) }
    }

    /// The page a file of the diff opens on in a tab (D4): its source in the code editor, at the
    /// line, so a web page (HTML, SVG) never renders and runs a repository's script there; a
    /// Markdown file its page, unless a line was asked for (the page has no lines); images, PDFs
    /// and media the browser tab's preview, which runs nothing.
    enum FilePage: Equatable {
        case editor
        case viewer
    }

    nonisolated static func filePage(for file: URL, line: Int?) -> FilePage {
        switch FilePageOpener.kind(for: file) {
        case .editor?: .editor
        case .markdown?: line == nil ? .viewer : .editor
        case nil: .viewer
        }
    }

    /// `cmux.diff.openFile` (D4): a file of tab `key`'s repository, checked by its provider.
    /// A tab opens where a page's file link opens (``LinkOpener``, from the diff tab's pane), on
    /// ``filePage(for:line:)``; the editor app goes through `file.open`, Finder through the reveal.
    /// False when nothing opened (the page then says so).
    fileprivate func openFile(_ file: URL, line: Int?, target: DiffFileTarget, from key: String) -> Bool {
        guard let pane = services.linkOpener.source(tab: key) else { return false }
        // A Cloud workspace's repository (#25581): the file's page reads it there. The provider
        // sends only `.tab` for one.
        if let machine = tabs[key]?.machine {
            guard target == .tab else { return false }
            return services.linkOpener.openFile(file, on: machine, from: pane, at: line.map { FilePosition(line: $0) })
        }
        switch target {
        case .tab:
            let position = line.map { FilePosition(line: $0) }
            let page = Self.filePage(for: file, line: line)
            return services.linkOpener.open(from: pane) { pane, placed in
                switch page {
                case .editor:
                    pane.services.viewers.editorPages.open(file, in: pane, focus: placed == nil, userChose: true,
                                                           at: position, placed: placed)
                    return true
                case .viewer:
                    return pane.services.viewers.openFile(file, in: pane, markdown: FilePageKind.isMarkdown(file),
                                                          at: position, placed: placed)
                }
            }
        case .editor:
            return services.registry.openAgentFile(path: file.path, target: .editor, pane: pane.paneKey)
        case .finder:
            NSWorkspace.shared.revealInBackground([file])
            return true
        }
    }

    // MARK: InternalPageProvider

    func makeView(for key: String, in window: WindowController?) -> NSView {
        // A store tab restored without its repository (the daemon keeps only
        // its page) shows the empty state: recents and a folder chooser.
        var tab = tabs[key] ?? Tab(repository: nil, source: .default)
        let host = DiffTabHost(service: self, key: key)
        let tabRuntime = tab.runtime ?? runtime
        let ready = tab.repository.map { tabRuntime.prepare(repository: $0, source: tab.source, turn: tab.turn) }
        let tabGit: (any DiffGitRunning)? = tab.gitLink.map { DiffAgentGit(link: $0) } ?? diffGit
        let provider = DiffPageProvider(ready: ready, sidecar: tabRuntime.sidecar, languages: tabRuntime.languages, host: host,
                                        stores: stores, git: tabGit, machine: tab.machine.map { machineName($0) })
        let native = AppPageNativeProvider(services: services, page: .diff)
        let routes = [PageRoute(prefix: "cmux.diff.", provider: provider), PageRoute(prefix: "cmux.app.", provider: native)]
        guard let page = PageWebView(descriptor: .diff, routes: routes, options: Self.engineOptions, surface: .diff,
                                     dynamicResources: DiffPatchSource { [weak provider] in provider?.ready }) else {
            ready?.cancel()
            return NSView()
        }
        native.anchor = { [weak page] in page }
        provider.confirmRevert = { [weak page] prompt in await DiffPageService.confirmRevert(prompt, over: page) }
        page.fileDrop = Self.folderDrop(provider: provider, page: page)
        tab.page = page
        tab.provider = provider
        tab.host = host
        tabs[key] = tab
        return page
    }

    /// The Revert sheet over the tab (a cmux dialog, drawn natively so page script cannot answer
    /// it). Revert is destructive, so Return presses nothing; Escape cancels.
    static func confirmRevert(_ prompt: DiffRevertPrompt, over page: PageWebView?) async -> Bool {
        let spec = CmuxDialogSpec(title: prompt.title, lines: prompt.lines,
                                  buttons: [.cancel(), CmuxDialogButton(id: "revert", title: prompt.confirm, role: .destructive)],
                                  identifier: "cmux.dialog.diffRevert")
        let scope: CmuxDialogScope = page.map { .tab($0) } ?? .app
        return await CmuxDialogCenter.shared.present(spec, in: scope).button == "revert"
    }

    /// An empty diff tab opens a folder dropped from Finder (the page cannot
    /// read its path): a dropped file opens its folder. The page reloads to
    /// show the repository.
    static func folderDrop(provider: DiffPageProvider, page: PageWebView) -> PageFileDrop {
        PageFileDrop(accepts: { [weak provider] url in url.isFileURL && provider?.isPicking == true }, open: { [weak provider, weak page] url in
            let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            // task-owner: one open of the dropped folder; ends when the tab shows it or refuses it
            Task {
                guard let provider, (try? await provider.open(folder: folder, source: .default)) != nil else {
                    return NSSound.beep()
                }
                page?.reload()
            }
        })
    }

    func tabClosed(_ key: String) {
        guard let tab = tabs.removeValue(forKey: key) else { return }
        for completion in tab.completions { completion.failed?(nil) }
        tab.reopen?.cancel()
        tab.page?.close()
        guard let provider = tab.provider else { return }
        let teardown = Task { await provider.close() }
        closing.append(teardown)
        // task-owner: drops the finished teardown from `closing`
        Task { [weak self] in
            await teardown.value
            self?.closing.removeAll { $0 == teardown }
        }
    }

    /// App quit: removes every tab's grant now (patches included). Sessions are
    /// not closed through the sidecar; the files they used go with the grant.
    func terminate() {
        for tab in tabs.values {
            tab.page?.close()
            tab.provider?.ready?.cancel()
        }
        tabs.removeAll()
        DiffPageRuntime.removeAllGrantsNow()
    }
}

/// One tab's ``DiffTabHosting``: the service, scoped to that tab.
final class DiffTabHost: DiffTabHosting {
    private weak var service: DiffPageService?
    private let key: String

    init(service: DiffPageService, key: String) {
        self.service = service
        self.key = key
    }

    func repository(at folder: URL) async -> DiffRepository? { await service?.repository(at: folder, for: key) }

    func prepare(_ repository: DiffRepository, source: DiffOpenSource) -> Task<DiffTabReady, any Error> {
        service?.prepare(repository, source: source, for: key)
            ?? Task { throw DiffTabFailure(title: repository.name, message: DiffPageStrings.unavailable) }
    }

    func recents() async -> JSONValue { await service?.recents.page() ?? ["items": .array([])] }

    func chooseFolder(start: URL?) async -> URL? { await service?.chooseFolder(start: start, for: key) }

    func opened(_ repository: DiffRepository, source: DiffOpenSource) {
        service?.opened(repository, source: source, in: key)
    }

    func openFile(_ file: URL, line: Int?, target: DiffFileTarget) -> Bool {
        service?.openFile(file, line: line, target: target, from: key) ?? false
    }
    func turn(for repository: String) -> DiffTurn? { service?.turn(for: key, in: repository) }
}
