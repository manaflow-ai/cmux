#if os(iOS)
import CmuxTabsKit
import CmuxMobileAgentChat
import CmuxMobileBrowserStream
import CmuxMobileDesign
import CmuxMobileModel
import Observation
import OSLog
import SwiftUI
import UIKit

private let tabsLog = Logger(subsystem: "dev.cmux.mobile", category: "tabs")

/// Drives one workspace's `TabsView`: the workspace's tabs (agent chats,
/// terminals, browsers) as TabsKit tabs, with the last tab used on this
/// device active when the workspace opens. Every activation is remembered
/// (`AppStore.noteOpened`), so the next open (or the next launch) starts there.
@MainActor
@Observable
public final class WorkspaceTabsSource: TabsDataSource {
    public let workspaceID: String
    /// The tab chosen on this screen. When it disappears (a new workspace
    /// whose placeholder tab became the Mac's real tab), the active tab
    /// falls back to the workspace's opening tab.
    private var selectedTabID: String?
    public var activeTabID: String? {
        guard let workspace else { return nil }
        if let selectedTabID, workspace.tabs.contains(where: { $0.id == selectedTabID }) { return selectedTabID }
        return store.openingTab(for: workspace)?.id
    }
    @ObservationIgnored let store: AppStore
    @ObservationIgnored let terminal: any TerminalTabContent
    @ObservationIgnored let sessions: AgentSessionDirectory
    /// Opens and closes tabs on the workspace's Mac (nil: nothing to open them on).
    @ObservationIgnored let creator: WorkspaceCreator?
    /// Leaves the workspace (back to the list).
    @ObservationIgnored public var exit: @MainActor () -> Void = {}
    @ObservationIgnored private var surfaces: [String: AgentChatSurface] = [:]
    /// Created with their tabs (never during a view update); each model is
    /// itself observable, so toolbar state follows the page.
    @ObservationIgnored private var browsers: [String: BrowserTabModel] = [:]
    /// Streamed browser tabs while linked to a Mac.
    @ObservationIgnored private let streamed = StreamedBrowserDirectory.shared
    /// The chrome insets the pages were last laid out with, for cards.
    @ObservationIgnored private var lastInsets = EdgeInsets(top: 62, leading: 0, bottom: 98, trailing: 0)
    @ObservationIgnored var pageHeight: CGFloat = 874
    /// A workspace created on this phone opens its first tab ready to type.
    /// Kept while the Mac creates it, since the placeholder tab becomes the
    /// Mac's real tab (a new page) once it confirms.
    @ObservationIgnored private(set) var focusOnOpen = false

    public init(store: AppStore, workspaceID: String, terminal: any TerminalTabContent = PlaceholderTerminalTabContent(),
                sessions: AgentSessionDirectory = .shared, creator: WorkspaceCreator? = nil) {
        self.store = store
        self.creator = creator
        self.workspaceID = workspaceID
        self.terminal = terminal
        self.sessions = sessions
        // Reads only. SwiftUI builds a screen's source while it updates the
        // view graph (a navigation destination re-runs on every change it
        // read), so a write here notifies the update that is running and it
        // re-runs forever: the workspace hang of verify/e2e-matrix.md #4.
        // The writes (remember the tab, consume the focus request) wait for
        // `opened()`, which the screen calls when it appears.
        if let workspace = store.workspace(id: workspaceID), let tab = store.openingTab(for: workspace) {
            selectedTabID = tab.id
        }
        focusOnOpen = store.wantsFocusOnOpen(workspaceID)
        // Linked to a Mac, browser tabs stream from it; otherwise each has a web view.
        if !streamed.isLive {
            for tab in store.workspace(id: workspaceID)?.tabs ?? [] where tab.kind == .browser {
                browsers[tab.id] = BrowserTabModel(url: tab.url)
            }
        }
    }

    public var workspace: Workspace? { store.workspace(id: workspaceID) }

    /// The screen appeared (an action, outside any view update): remembers
    /// the opening tab and consumes this workspace's focus request. `init`
    /// already armed `focusOnOpen` from it; a page that appeared first may
    /// have used it, so this only consumes (re-arming would raise the
    /// keyboard on the next page shown).
    public func opened() {
        if let activeTabID { store.noteOpened(tabID: activeTabID, in: workspaceID) }
        _ = store.takeFocusOnOpen(workspaceID)
    }

    var macName: String {
        guard let macID = workspace?.macID else { return "Mac" }
        return store.teams.flatMap(\.macs).first { $0.id == macID }?.name ?? "Mac"
    }

    private func workspaceTab(_ id: String) -> WorkspaceTab? {
        workspace?.tabs.first { $0.id == id }
    }

    // MARK: Tabs

    public var tabs: [TabsKitTab] {
        guard let workspace else { return [] }
        return workspace.tabs.map { kitTab($0, in: workspace) }
    }

    /// What the Mac can open in this workspace right now, then what it can't
    /// yet with why (a tap says why instead of opening). Every option that
    /// opens becomes a real tab on the Mac. Agent chats are one model-agnostic
    /// entry, as on the Mac (New Agent Chat: its default agent), plus a chooser
    /// for another agent or model.
    public var newTabOptions: [TabsKitNewTabOption] {
        guard let workspace, let creator else { return [] }
        let kinds = creator.backend.tabKinds(on: workspace.macID)
        var options: [TabsKitNewTabOption] = []
        for kind in kinds {
            options.append(Self.option(kind))
            if case .agent = kind { options.append(Self.chooseAgentOption) }
        }
        for (kind, _) in creator.backend.unavailableTabKinds(on: workspace.macID)
        where !kinds.contains(where: { $0.family == kind.family }) {
            var option = Self.option(kind)
            option.id = Self.unavailablePrefix + option.id
            options.append(option)
        }
        return options
    }

    static let unavailablePrefix = "unavailable:"
    /// The Mac's wording for an agent chat (`palette.newAgentChat`).
    static let newAgentChatTitle = "New Agent Chat"
    static let chooseAgentOption = TabsKitNewTabOption(id: "agent-choose", title: "New Agent Chat With…",
                                                       systemImage: "slider.horizontal.3", kind: TabsKitTabKind("agent"))

    static func option(_ kind: NewTabKind) -> TabsKitNewTabOption {
        switch kind {
        case .agent(let start):
            let id = start == .macDefault ? "agent" : "agent:\(start.harness ?? "")|\(start.model ?? "")"
            return TabsKitNewTabOption(id: id, title: newAgentChatTitle, systemImage: "sparkle", kind: TabsKitTabKind("agent"))
        case .terminal:
            return TabsKitNewTabOption(id: "terminal", title: "New Terminal", systemImage: "apple.terminal", kind: .terminal)
        case .browser:
            return TabsKitNewTabOption(id: "browser", title: "New Browser Tab", systemImage: "globe", kind: .web)
        }
    }

    static func kind(of option: TabsKitNewTabOption) -> NewTabKind {
        if option.id == "agent" { return .agentChat }
        if option.id.hasPrefix("agent:") {
            let parts = option.id.dropFirst("agent:".count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let harness = parts.first.flatMap { $0.isEmpty ? nil : $0 }
            let model = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            return .agent(AgentChatStart(harness: harness, model: model))
        }
        return option.id == "browser" ? .browser : .terminal
    }

    // MARK: Agent chooser

    /// The agent chooser is up (New Agent Chat With…): the screen shows it as a sheet.
    public var choosingAgent = false

    /// The Mac's agents for the chooser.
    public func agentCatalog() async throws -> AgentCatalog {
        guard let workspace, let creator else { throw WorkspaceCreationError("Connect to \(macName) first.") }
        return try await creator.backend.agentCatalog(on: workspace.macID)
    }

    /// The chooser's Start Chat: a chat with that agent and model.
    public func startAgentChat(_ start: AgentChatStart) {
        choosingAgent = false
        beginTab(Self.option(.agent(start)))
    }

    func kitTab(_ tab: WorkspaceTab, in workspace: Workspace) -> TabsKitTab {
        switch tab.kind {
        case .agent:
            // A new session takes its title from the agent, or its first prompt, after a turn.
            let session = AgentSessionDirectory.shared.existingStore(id: tab.id, macID: workspace.macID)?.displayTitle ?? tab.subtitle ?? tab.title
            return TabsKitTab(
                id: tab.id, kind: TabsKitTabKind("agent"), title: session, subtitle: "\(tab.title) · \(workspace.title)",
                systemImage: tab.isPinned ? "pin.fill" : "sparkle",
                address: .title(session, subtitle: "\(tab.title) · \(workspace.title)"),
                // Back leaves the workspace: the tab has no history of its own.
                navigation: TabsKitNavigationState(canGoBack: true),
                features: [.history, .pageMenu]
            )
        case .terminal:
            let directory = tab.subtitle ?? workspace.directory
            // "Reattaching…" replaces the directory in the pill only after a slow reattach (P5).
            let status = terminal.statusSubtitle(for: tab)
            return TabsKitTab(
                id: tab.id, kind: .terminal, title: tab.title, subtitle: directory,
                systemImage: tab.isPinned ? "pin.fill" : "apple.terminal",
                address: .title(tab.title, subtitle: status ?? directory, monospaced: status == nil),
                navigation: TabsKitNavigationState(canGoBack: true),
                features: [.history, .pageMenu],
                statusBarStyle: .lightContent
            )
        case .browser:
            let model: (any BrowserTabState)? = streamed.model(tab: tab.id, url: tab.url, macID: workspace.macID) ?? browsers[tab.id]
            // A new tab's about:blank is no address: the field reads "Search or enter website",
            // never "about:blank" (VoiceOver read it after a navigation, parity finding 4).
            let url = (model?.url ?? tab.url).flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
            // Safari's short label: the host, or a local file's name (a file: URL has no host,
            // and its full path overflowed the collapsed pill).
            let host = url.map(TabsKitAddress.displayLabel(for:)) ?? ""
            return TabsKitTab(
                id: tab.id, kind: .web, title: Self.browserTitle(model?.title, fallback: tab.title, url: url, label: host),
                subtitle: host, systemImage: tab.isPinned ? "pin.fill" : "globe",
                address: url == nil ? .placeholder("Search or enter website") : .url(display: host, editingText: url?.absoluteString ?? ""),
                // Back walks the page history first, then leaves the workspace.
                navigation: TabsKitNavigationState(canGoBack: true, canGoForward: model?.canGoForward ?? false,
                                                   isLoading: model?.isLoading ?? false, progress: model?.progress ?? 1),
                features: .web
            )
        case .simulator:
            // A Mac phone tab: no address or page history; Back leaves the workspace.
            return TabsKitTab(
                id: tab.id, kind: .web, title: tab.title, subtitle: "Simulator",
                systemImage: tab.isPinned ? "pin.fill" : "iphone",
                address: .title(tab.title, subtitle: "Simulator on \(macName)"),
                navigation: TabsKitNavigationState(canGoBack: true),
                features: [.history, .pageMenu],
                statusBarStyle: .lightContent
            )
        }
    }

    /// A page without its own title shows the short label, never the raw URL
    /// (a file page's title is its whole path).
    static func browserTitle(_ pageTitle: String?, fallback: String, url: URL?, label: String) -> String {
        let title = pageTitle.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        guard let url, !label.isEmpty else { return title }
        let raw = [url.absoluteString, url.absoluteString.removingPercentEncoding ?? url.absoluteString, url.path]
        return title.isEmpty || raw.contains(title) ? label : title
    }

    public func activate(_ id: TabsKitTab.ID) {
        guard workspaceTab(id) != nil else { return }
        // verify/e2e: the touch that switches tabs (the rig's tab_switch t0).
        ConnectTimeline.shared.event("tab_activate", detail: id)
        selectedTabID = id
        store.noteOpened(tabID: id, in: workspaceID)
        CmuxMobileTheme.standard.haptics.selection()
    }

    /// Closes the tab on the Mac, then here. TabsKit keeps the card hidden
    /// meanwhile; a refusal returns false, so the card comes back, with a
    /// notice.
    /// A close waiting for the person to confirm it (a program is running in
    /// the tab, Codex QA F9). The screen shows the dialog.
    public private(set) var pendingClose: PendingClose?

    public struct PendingClose: Identifiable {
        public let id = UUID()
        public let title: String
        /// Filled in when the Mac answers a pending question (D7).
        public internal(set) var message: String
        fileprivate let resume: CheckedContinuation<Bool, Never>
    }

    /// The person answered the close dialog.
    public func resolvePendingClose(_ close: Bool) {
        guard let pending = pendingClose else { return }
        pendingClose = nil
        pending.resume.resume(returning: close)
    }

    public func close(_ id: TabsKitTab.ID) async -> Bool {
        guard let workspace, let tab = workspace.tabs.first(where: { $0.id == id }) else { return true }
        // A working agent or a program running in the tab: a phone close ends
        // its terminal with no way back. Ask first, exactly as the Mac's tab
        // close does (TabCloseGuard), from the Mac's own process state.
        guard await confirmClose([tab], in: workspace) else { return false }
        guard let creator else {
            show("Connect to \(macName) first.")
            CmuxMobileTheme.standard.haptics.error()
            return false
        }
        do {
            try await creator.backend.closeTab(tab, in: workspace)
        } catch {
            show(TabNotice(action: .close(title: tab.title), macName: macName, reason: Self.message(error)))
            CmuxMobileTheme.standard.haptics.error()
            return false
        }
        let next = store.removeTab(id, from: workspaceID)
        surfaces[id] = nil
        browsers[id] = nil
        streamed.drop(tab: id, macID: store.workspace(id: workspaceID)?.macID)
        if selectedTabID == id || workspaceTab(selectedTabID ?? "") == nil {
            selectedTabID = next?.id
            if let next { store.noteOpened(tabID: next.id, in: workspaceID) }
        }
        return true
    }

    /// Whether closing `tabs` may go ahead: at once when no closing terminal
    /// is doing work, else after the person confirms the Mac's question
    /// ("Close “name”?" / "Still running: sleep."). A newer close question
    /// cancels an older one that is still shown.
    func confirmClose(_ tabs: [WorkspaceTab], in workspace: Workspace) async -> Bool {
        let guardrail = TabCloseGuard()
        let asked = guardrail.terminalsToAsk(tabs)
        let hasAgent = tabs.contains { guardrail.workingAgent($0) != nil }
        guard hasAgent || !asked.isEmpty else { return true }
        // The grid read the programs when it opened (D7): a busy tab asks at once.
        let plan = TabClosePromptPlan(closing: tabs, cached: hasAgent ? nil : programCache.programs(of: asked.map(\.id), now: Self.uptime))
        guard !hasAgent, let creator else {
            guard let prompt = plan.immediate else { return true }
            return await ask(prompt, title: prompt.title, updatedBy: nil, plan: plan)
        }
        let fetch = Task { @MainActor [weak self] in
            let programs = await creator.backend.runningPrograms(of: asked, in: workspace)
            if asked.count == 1 { self?.programCache.record(tabID: asked[0].id, programs: programs, at: Self.uptime) }
            return programs
        }
        if let prompt = plan.immediate {
            return await ask(prompt, title: prompt.title, updatedBy: fetch, plan: plan)
        }
        // Nothing known: the Mac answers first when it is quick; otherwise the
        // question shows at once as pending and the answer fills it in.
        let quick: [String]? = await withTaskGroup(of: [String]?.self) { group in
            group.addTask { await fetch.value }
            group.addTask {
                try? await Task.sleep(for: TabClosePromptPlan.pendingAfter)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let quick {
            switch plan.afterReply(programs: quick) {
            case .close: return true
            case .ask(let prompt): return await ask(prompt, title: prompt.title, updatedBy: nil, plan: plan)
            }
        }
        return await ask(plan.pending, title: plan.pending.title, updatedBy: fetch, plan: plan)
    }

    /// Shows the close question; with `updatedBy`, the Mac's answer replaces
    /// its message, or closes the tab when a pending question learns the
    /// shell is idle (`TabClosePromptPlan.afterReply`).
    private func ask(_ prompt: TabCloseGuard.Prompt, title: String, updatedBy fetch: Task<[String], Never>?,
                     plan: TabClosePromptPlan) async -> Bool {
        resolvePendingClose(false)
        return await withCheckedContinuation { continuation in
            let pending = PendingClose(title: title, message: prompt.message, resume: continuation)
            pendingClose = pending
            guard let fetch else { return }
            let id = pending.id
            Task { @MainActor [weak self] in
                let programs = await fetch.value
                guard let self, self.pendingClose?.id == id else { return }
                switch plan.afterReply(programs: programs) {
                case .ask(let answer):
                    if self.pendingClose?.message != answer.message { self.pendingClose?.message = answer.message }
                case .close:
                    self.resolvePendingClose(true)
                }
            }
        }
    }

    /// Programs per terminal tab, read while the grid shows (D7).
    @ObservationIgnored private var programCache = TabProgramCache()
    @ObservationIgnored private var programPrefetch: Task<Void, Never>?
    /// How often the grid reads its terminals' programs (within the cache's age).
    static let programPrefetchInterval: Duration = .milliseconds(2500)
    static var uptime: Double { ProcessInfo.processInfo.systemUptime }

    /// The grid shows: its terminals' foreground programs are read now and
    /// every `programPrefetchInterval` (one bounded `process-info` per terminal).
    private func prefetchPrograms(_ visible: Bool) {
        programPrefetch?.cancel()
        programPrefetch = nil
        guard visible, let creator else { return }
        programPrefetch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.prefetchProgramsOnce(creator)
                try? await Task.sleep(for: WorkspaceTabsSource.programPrefetchInterval)
            }
        }
    }

    private func prefetchProgramsOnce(_ creator: WorkspaceCreator) async {
        guard let workspace else { return }
        let backend = creator.backend
        for tab in TabCloseGuard().terminalsToAsk(workspace.tabs) {
            guard !Task.isCancelled else { return }
            let programs = await backend.runningPrograms(of: [tab], in: workspace)
            programCache.record(tabID: tab.id, programs: programs, at: Self.uptime)
        }
    }

    /// The workspace's toast (a tab that could not be opened or closed): one short line
    /// (`TabNotice`). `WorkspaceScreen` draws it as a `cmuxMobileDismissibleToast` above the
    /// bottom chrome; it clears after `noticeLifetime`, on a swipe or on a tap.
    public private(set) var toastText: String?
    /// TabsKit's own toast is never used: it draws at the top, over the title and Back
    /// (upstream request U6), so the kit always sees no notice.
    public var notice: String? { nil }
    public func clearNotice() { toastText = nil }

    /// How long a toast stays (a UI timeout, not synchronization).
    static let noticeLifetime: Duration = .seconds(4)

    private func show(_ text: String) {
        toastText = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.noticeLifetime)
            if self?.toastText == text { withAnimation { self?.clearNotice() } }
        }
    }

    #if DEBUG
    /// `-cmux-mobile-toast-demo`: the live report's refusal as a toast that stays until dismissed
    /// (placement and gesture captures).
    func showDemoToast() {
        toastText = TabNotice(action: .open(optionTitle: "New Claude Chat"), macName: macName,
                              reason: "cwd is refused: a remote WebSocket connection may use only a known project or a configured webRoots folder").text
    }
    #endif

    /// The short line in the toast; the Mac's reason goes to the log only.
    private func show(_ notice: TabNotice) {
        tabsLog.error("tab request refused on \(self.macName, privacy: .public): \(notice.detail, privacy: .public)")
        show(notice.text)
    }

    /// "this Mac" / "your Mac" in a phone-written line, as the Mac's name.
    private func named(_ text: String) -> String {
        text.replacingOccurrences(of: "your Mac", with: macName).replacingOccurrences(of: "this Mac", with: macName)
    }

    /// A kind the Mac can't open yet: say why, in the Mac's name.
    private func showUnavailable(_ option: TabsKitNewTabOption) {
        let kind = Self.kind(of: TabsKitNewTabOption(id: String(option.id.dropFirst(Self.unavailablePrefix.count)),
                                                     title: option.title, systemImage: option.systemImage, kind: option.kind))
        guard let workspace, let creator,
              let reason = creator.backend.unavailableTabKinds(on: workspace.macID).first(where: { $0.kind.family == kind.family })?.reason
        else {
            show("\(option.title) isn't available on \(macName) right now.")
            return
        }
        show(named(reason))
        CmuxMobileTheme.standard.haptics.error()
    }

    /// Opens the tab on the Mac and activates it once the Mac lists it (so a
    /// terminal attaches at once and a chat is bound to its session). A
    /// refusal shows as a notice; nothing phone-only is ever added.
    ///
    /// TabsKit puts a placeholder card in the grid while `createTab` is running and
    /// reflows the grid around it (upstream request U7). So `createTab` returns at once
    /// with no tab, and the request runs here: the grid keeps its cards until the Mac
    /// lists the new tab, the workspace screen shows "Opening…" meanwhile
    /// (`pendingTabTitle`), and a refusal leaves the grid exactly as it was. Once the Mac
    /// lists the tab it becomes active and `openedTab` asks the screen to open it.
    public func createTab(_ option: TabsKitNewTabOption) async -> TabsKitTab.ID? {
        beginTab(option)
    }

    @discardableResult
    private func beginTab(_ option: TabsKitNewTabOption) -> TabsKitTab.ID? {
        if option.id == Self.chooseAgentOption.id {
            choosingAgent = true
            return nil
        }
        if option.id.hasPrefix(Self.unavailablePrefix) {
            showUnavailable(option)
            return nil
        }
        // One tab at a time; a second request says so instead of doing nothing (full verify D8).
        if let pending = pendingTabTitle {
            tabsLog.info("tab request \(option.id, privacy: .public) while \(pending, privacy: .public) is opening")
            show("Still opening \(pending). Try again once it's open.")
            return nil
        }
        tabsLog.info("tab request \(option.id, privacy: .public) on \(self.macName, privacy: .public)")
        pendingTabTitle = option.title
        Task { @MainActor [weak self] in
            guard let self else { return }
            let id = await self.requestTab(option)
            self.pendingTabTitle = nil
            if let id { self.openedTab = id }
        }
        return nil
    }

    /// The new-tab option being created on the Mac ("New Claude Chat"), or nil.
    public private(set) var pendingTabTitle: String?
    /// A tab the Mac just created and this phone made active: the screen leaves the
    /// grid for it, then clears this.
    public var openedTab: TabsKitTab.ID?

    /// Asks the Mac for the tab and waits for it. Nothing is added here before the Mac
    /// answers; a refusal shows a toast and changes nothing.
    func requestTab(_ option: TabsKitNewTabOption) async -> TabsKitTab.ID? {
        guard let workspace else {
            show("This workspace is no longer on \(macName).")
            return nil
        }
        guard let creator, !creator.backend.tabKinds(on: workspace.macID).isEmpty else {
            show("Connect to \(macName) first.")
            return nil
        }
        let kind = Self.kind(of: option)
        let tab: WorkspaceTab
        let asked = Self.uptime
        do {
            tab = try await creator.backend.createTab(kind, in: workspace)
            // T-TABS-06 timing: the Mac's create and list (the page's attach
            // and first output follow in the terminal log).
            tabsLog.notice("new tab \(tab.id, privacy: .public) (\(option.id, privacy: .public)) listed by the Mac \(Int((Self.uptime - asked) * 1000), privacy: .public) ms after the pick")
        } catch let error as WorkspaceCreationError where error.isForPerson {
            tabsLog.error("tab request refused on \(self.macName, privacy: .public): \(error.message, privacy: .public)")
            show(named(error.message))
            CmuxMobileTheme.standard.haptics.error()
            return nil
        } catch {
            show(TabNotice(action: .open(optionTitle: option.title), macName: macName, reason: Self.message(error)))
            CmuxMobileTheme.standard.haptics.error()
            return nil
        }
        // The mock keeps tabs in its own store; a live Mac's list already has it.
        if store.workspace(id: workspaceID)?.tabs.contains(where: { $0.id == tab.id }) != true {
            store.appendTab(tab, to: workspaceID)
        }
        let id = tab.id
        if tab.kind == .browser, !streamed.isLive, browsers[id] == nil { browsers[id] = BrowserTabModel(url: tab.url) }
        // A new chat opens ready to type (SPEC 6.2; ChatGPT, Claude and Grok
        // open a new chat with the keyboard up).
        if tab.kind == .agent { surface(id).composerFocused = true }
        activate(id)
        // A new terminal is the same: a fresh shell's next step is a
        // command, and terminal apps (Blink, Termius, Prompt) raise the
        // keyboard for a new session.
        if tab.kind == .terminal, let workspace = self.workspace { terminal.focusInput(for: tab, in: workspace) }
        return id
    }

    static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: Per-tab state

    /// A page appeared: in a workspace this phone just created, its active
    /// agent chat or terminal opens with the keyboard up.
    func pageAppeared(_ tabID: String) {
        guard focusOnOpen, tabID == activeTabID, let workspace, let tab = workspaceTab(tabID) else { return }
        switch tab.kind {
        case .agent: surface(tabID).composerFocused = true
        case .terminal: terminal.focusInput(for: tab, in: workspace)
        case .browser, .simulator: break
        }
        if !store.isPending(workspaceID) { focusOnOpen = false }
    }

    func surface(_ id: String) -> AgentChatSurface {
        if let surface = surfaces[id] { return surface }
        let surface = AgentChatSurface()
        surfaces[id] = surface
        return surface
    }

    func chatStore(_ tab: WorkspaceTab, _ workspace: Workspace) -> AgentChatStore {
        sessions.store(workspace: workspace, tab: tab, macName: macName)
    }

    /// The tab's page: streamed from the Mac while linked, else a local web view.
    func browser(_ tab: WorkspaceTab) -> any BrowserTabState {
        if let model = streamed.model(tab: tab.id, url: tab.url, macID: store.workspace(id: workspaceID)?.macID) { return model }
        return localBrowser(tab)
    }

    /// A Mac phone tab's simulator, streamed while linked (nil otherwise).
    func simulator(_ tab: WorkspaceTab) -> StreamedBrowserModel? {
        streamed.simulatorModel(tab: tab.id, macID: store.workspace(id: workspaceID)?.macID)
    }

    func localBrowser(_ tab: WorkspaceTab) -> BrowserTabModel {
        if let model = browsers[tab.id] { return model }
        let model = BrowserTabModel(url: tab.url)
        browsers[tab.id] = model
        return model
    }

    // MARK: Content

    public func content(for kit: TabsKitTab, context: TabsKitContentContext) -> some View {
        WorkspaceTabPage(source: self, tabID: kit.id, context: context)
    }

    public func card(for kit: TabsKitTab) -> some View {
        WorkspaceTabCard(source: self, tabID: kit.id, insets: lastInsets)
    }

    public func accessory(for kit: TabsKitTab, context: TabsKitContentContext) -> some View {
        WorkspaceTabAccessory(source: self, tabID: kit.id, context: context)
    }

    func remember(_ insets: EdgeInsets, pageHeight: CGFloat) {
        if insets != lastInsets { lastInsets = insets }
        self.pageHeight = pageHeight
    }

    public func overviewWillAppear() {
        let inactive = (workspace?.tabs ?? []).filter { $0.kind == .terminal && $0.id != activeTabID }
        if !inactive.isEmpty { terminal.overviewWillAppear(inactive: inactive) }
        guard let id = activeTabID else { return }
        if let tab = workspaceTab(id), tab.kind == .browser { browser(tab).takeSnapshot() }
        if let tab = workspaceTab(id), tab.kind == .simulator { simulator(tab)?.takeSnapshot() }
        if let tab = workspaceTab(id), tab.kind == .terminal { terminal.overviewWillAppear(active: tab) }
    }

    public func overviewVisibilityChanged(_ visible: Bool) {
        prefetchPrograms(visible)
        terminal.overviewVisibilityChanged(visible) { [weak self] in
            (self?.workspace?.tabs ?? []).filter { $0.kind == .terminal }
        }
    }

    public func overviewScrollingChanged(_ scrolling: Bool) {
        terminal.overviewScrollingChanged(scrolling)
    }

    public func showStaticCard(for id: TabsKitTab.ID) -> Bool {
        guard let tab = workspaceTab(id), tab.kind == .terminal else { return false }
        return terminal.showsStaticCard(for: tab)
    }

    // MARK: Toolbar actions

    public func goBack(_ id: TabsKitTab.ID) {
        if let tab = workspaceTab(id), tab.kind == .browser, browser(tab).canGoBack {
            browser(tab).goBack()
        } else {
            exit()
        }
    }

    public func goForward(_ id: TabsKitTab.ID) {
        if let tab = workspaceTab(id), tab.kind == .browser { browser(tab).goForward() }
    }

    public func reloadOrStop(_ id: TabsKitTab.ID) {
        if let tab = workspaceTab(id), tab.kind == .browser { browser(tab).reloadOrStop() }
    }

    public func navigate(_ id: TabsKitTab.ID, to text: String) {
        guard let tab = workspaceTab(id), tab.kind == .browser else { return }
        browser(tab).navigate(to: text)
    }

    // MARK: Tab edits (the Mac's Rename Tab…, Duplicate Tab, drag to reorder)

    var canEditTabs: Bool {
        guard let workspace, let creator else { return false }
        return creator.backend.canEditTabs(on: workspace.macID)
    }

    /// The tab whose name the person is editing (the screen shows the field).
    public var renamingTab: WorkspaceTab?

    public func startRename(_ id: TabsKitTab.ID) {
        renamingTab = workspaceTab(id)
    }

    /// Renames at once; the old title comes back if the Mac refuses.
    public func rename(_ id: TabsKitTab.ID, to title: String) async {
        renamingTab = nil
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let workspace, let creator, let tab = workspaceTab(id), title != tab.title,
              let old = store.renameTab(id, in: workspaceID, to: title) else { return }
        do {
            try await creator.backend.renameTab(tab, in: workspace, to: title)
        } catch {
            store.renameTab(id, in: workspaceID, to: old)
            show(TabNotice(action: .rename(title: old), macName: macName, reason: Self.message(error)))
            CmuxMobileTheme.standard.haptics.error()
        }
    }

    /// Opens a copy of the tab on the Mac and goes to it once the Mac lists it.
    public func duplicate(_ id: TabsKitTab.ID) async {
        guard let workspace, let creator, let tab = workspaceTab(id), pendingTabTitle == nil else { return }
        pendingTabTitle = "Duplicate Tab"
        defer { pendingTabTitle = nil }
        do {
            let copy = try await creator.backend.duplicateTab(tab, in: workspace)
            if store.workspace(id: workspaceID)?.tabs.contains(where: { $0.id == copy.id }) != true {
                store.appendTab(copy, to: workspaceID)
            }
            activate(copy.id)
            openedTab = copy.id
        } catch let error as WorkspaceCreationError where error.isForPerson {
            show(named(error.message))
            CmuxMobileTheme.standard.haptics.error()
        } catch {
            show(TabNotice(action: .open(optionTitle: "New \(tab.kind == .browser ? "Browser Tab" : "Terminal")"), macName: macName,
                           reason: Self.message(error)))
            CmuxMobileTheme.standard.haptics.error()
        }
    }

    /// A web link tapped in a terminal tab (the Mac's Cmd-click): a cmux browser tab at `url`
    /// beside the terminal on the Mac, shown here once the Mac lists it.
    public func openLink(_ url: URL, fromTab id: TabsKitTab.ID) async {
        // No Mac to open it on (the workspace went away): Safari, never nothing.
        guard let workspace, let creator, let tab = workspaceTab(id) else {
            await UIApplication.shared.open(url)
            return
        }
        if let pending = pendingTabTitle {
            show("Still opening \(pending). Try again once it's open.")
            return
        }
        let title = WorkspaceTabsSource.option(.browser).title
        pendingTabTitle = title
        defer { pendingTabTitle = nil }
        do {
            let opened = try await creator.backend.openLink(url, besides: tab, in: workspace)
            if store.workspace(id: workspaceID)?.tabs.contains(where: { $0.id == opened.id }) != true {
                store.appendTab(opened, to: workspaceID)
            }
            activate(opened.id)
            openedTab = opened.id
        } catch let error as WorkspaceCreationError where error.isForPerson {
            show(named(error.message))
            CmuxMobileTheme.standard.haptics.error()
        } catch {
            show(TabNotice(action: .open(optionTitle: title), macName: macName, reason: Self.message(error)))
            CmuxMobileTheme.standard.haptics.error()
        }
    }

    /// The Mac's wording (`terminal.restart.button`, `action.tab.restart`).
    public static let restartShellTitle = "Restart Shell Here"

    /// Restart Shell Here: the Mac starts the tab's shell again; the tab turns live when
    /// the Mac's tree says so.
    public func restartShell(_ id: TabsKitTab.ID) async {
        guard let workspace, let creator, let tab = workspaceTab(id), tab.hasEndedShell else { return }
        do {
            try await creator.backend.restartShell(tab, in: workspace)
        } catch {
            show(TabNotice(action: .other(verb: "restart", title: tab.title), macName: macName, reason: Self.message(error)))
            CmuxMobileTheme.standard.haptics.error()
        }
    }

    public var supportsReordering: Bool { canEditTabs }

    /// Drag in the grid: here at once, then on the Mac (`move-tab` to the place of the
    /// tab it lands on); a refusal puts it back.
    public func moveTab(_ id: TabsKitTab.ID, to index: Int) {
        guard let workspace, let creator, let tab = workspaceTab(id),
              let from = workspace.tabs.firstIndex(where: { $0.id == id }), from != index,
              workspace.tabs.indices.contains(index) else { return }
        let target = workspace.tabs[index]
        store.moveTab(id, in: workspaceID, to: index)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await creator.backend.moveTab(tab, to: target, in: workspace)
            } catch {
                self.store.moveTab(id, in: self.workspaceID, to: from)
                if let error = error as? WorkspaceCreationError, error.isForPerson {
                    self.show(self.named(error.message))
                } else {
                    self.show(TabNotice(action: .move(title: tab.title), macName: self.macName, reason: Self.message(error)))
                }
            }
        }
    }

    // MARK: Move to another workspace, pins, groups, chat menu (verify/parity-mac.md)

    /// The tab whose destination the person is picking (Move Tab to Workspace…).
    public var movingTab: WorkspaceTab?
    /// The tab whose group the person is picking (Add Tab to Group…).
    public var addingToGroupTab: WorkspaceTab?
    /// The tab whose group's actions are open (the Mac's group chip menu).
    public var groupActionsTab: WorkspaceTab?
    /// The tab whose group the person is renaming (Rename Tab Group…).
    public var renamingGroupTab: WorkspaceTab?

    /// The other workspaces on this workspace's Mac, in list order (Move Tab to Workspace…).
    public var otherWorkspaces: [Workspace] {
        guard let workspace else { return [] }
        return store.workspaces.filter { $0.macID == workspace.macID && $0.id != workspace.id && !store.isPending($0.id) }
    }

    /// The groups of this workspace other than `tab`'s own, once each, in tab order.
    public func groups(besides tab: WorkspaceTab) -> [WorkspaceTab.TabGroupRef] {
        var seen = Set<String>()
        return (workspace?.tabs ?? []).compactMap(\.group).filter { $0.id != tab.group?.id && seen.insert($0.id).inserted }
    }

    /// Move Tab to Workspace… (`destinationID`) or Move Tab to New Workspace (nil). The tab
    /// leaves this workspace once the Mac moved it; this screen stays (the Mac's view is its own),
    /// and leaves when it was the last tab.
    public func move(_ id: TabsKitTab.ID, to destinationID: String?) async {
        movingTab = nil
        guard let workspace, let creator, let tab = workspaceTab(id) else { return }
        if workspace.isHome, destinationID == nil { return show("Home's tabs stay in Home.") }
        let destination = destinationID.flatMap { store.workspace(id: $0) }
        if destinationID != nil, destination == nil { return show("That workspace is no longer on \(macName).") }
        do {
            let landed = try await creator.backend.moveTab(tab, from: workspace, toWorkspace: destination)
            if landed?.id == workspaceID { return }
            let next = store.removeTab(id, from: workspaceID)
            // The mock keeps tabs in its own store; a live Mac's list already moved it.
            if let landed, store.workspace(id: landed.id)?.tabs.contains(where: { $0.id == id }) == false {
                store.appendTab(tab, to: landed.id)
            }
            surfaces[id] = nil
            if selectedTabID == id { selectedTabID = next?.id }
            show("Moved \(tab.title) to \(landed?.title ?? destination?.title ?? "a new workspace").")
            CmuxMobileTheme.standard.haptics.success()
            if self.workspace?.tabs.isEmpty ?? true { exit() }
        } catch let error as WorkspaceCreationError where error.isForPerson {
            show(named(error.message))
            CmuxMobileTheme.standard.haptics.error()
        } catch {
            show(TabNotice(action: .move(title: tab.title), macName: macName, reason: Self.message(error)))
            CmuxMobileTheme.standard.haptics.error()
        }
    }

    /// Pin Tab / Unpin Tab: here at once, then on the Mac; a refusal puts it back.
    public func setPinned(_ id: TabsKitTab.ID, _ pinned: Bool) async {
        guard let workspace, let creator, let tab = workspaceTab(id), tab.isPinned != pinned else { return }
        store.updateTab(id, in: workspaceID) { $0.pinned = pinned }
        do {
            try await creator.backend.setTabPinned(tab, in: workspace, pinned: pinned)
        } catch {
            store.updateTab(id, in: workspaceID) { $0.pinned = tab.pinned }
            show(error, doing: pinned ? "pin" : "unpin", tab.title)
        }
    }

    /// A tab group change from the tab's menu. Membership and names change here at once (the
    /// Mac's list confirms them); Close Tab Group waits for the Mac, as closing a tab does.
    public func editGroup(_ edit: TabGroupEdit, _ id: TabsKitTab.ID) async {
        groupActionsTab = nil
        addingToGroupTab = nil
        renamingGroupTab = nil
        guard let workspace, let creator, let tab = workspaceTab(id) else { return }
        if case .rename(let name) = edit, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        // Close Tab Group asks as closing its tabs one by one would (A2).
        if edit == .close, let group = tab.group {
            let members = workspace.tabs.filter { $0.group?.id == group.id }
            guard await confirmClose(members, in: workspace) else { return }
        }
        let before = workspace.tabs
        apply(edit, to: tab)
        do {
            try await creator.backend.editTabGroup(edit, tab: tab, in: workspace)
            if edit == .close, let group = tab.group {
                for member in before where member.group?.id == group.id {
                    _ = store.removeTab(member.id, from: workspaceID)
                    surfaces[member.id] = nil
                    browsers[member.id] = nil
                    streamed.drop(tab: member.id)
                }
                if workspaceTab(selectedTabID ?? "") == nil { selectedTabID = self.workspace?.tabs.first?.id }
                if self.workspace?.tabs.isEmpty ?? true { exit() }
            }
        } catch {
            for old in before { store.updateTab(old.id, in: workspaceID) { $0.group = old.group } }
            if let error = error as? WorkspaceCreationError, error.isForPerson {
                show(named(error.message))
            } else {
                show(TabNotice(action: .group(edit.title), macName: macName, reason: Self.message(error)))
            }
            CmuxMobileTheme.standard.haptics.error()
        }
    }

    /// What an edit does to this phone's copy before the Mac lists it.
    private func apply(_ edit: TabGroupEdit, to tab: WorkspaceTab) {
        let group = tab.group
        func members(_ change: (inout WorkspaceTab) -> Void) {
            guard let group else { return }
            for member in workspace?.tabs ?? [] where member.group?.id == group.id { store.updateTab(member.id, in: workspaceID, change) }
        }
        switch edit {
        case .create:
            let used = Set((workspace?.tabs ?? []).compactMap { $0.group?.color })
            store.updateTab(tab.id, in: workspaceID) { $0.group = WorkspaceTab.TabGroupRef(id: "pending-\(tab.id)", color: WorkspaceTab.TabGroupRef.nextColor(used: used)) }
        case .add(let id):
            let target = groups(besides: tab).first { $0.id == id } ?? WorkspaceTab.TabGroupRef(id: id)
            store.updateTab(tab.id, in: workspaceID) { $0.group = target }
        case .remove:
            store.updateTab(tab.id, in: workspaceID) { $0.group = nil }
        case .rename(let name):
            members { $0.group?.name = name }
        case .ungroup:
            members { $0.group = nil }
        case .save:
            members { $0.group?.isSaved = true }
        case .unsave:
            members { $0.group?.isSaved = false }
        case .close:
            break
        }
    }

    /// The chat menu's Fork and Archive (the Mac's agent pane labels).
    private func chatItems(_ tab: WorkspaceTab) -> [TabsKitMenuItem] {
        guard canEditTabs else { return [] }
        return [
            TabsKitMenuItem(title: "Fork", systemImage: "arrow.triangle.branch") { [weak self] in Task { await self?.fork(tab.id) } },
            TabsKitMenuItem(title: "Archive", systemImage: "archivebox") { [weak self] in Task { await self?.archive(tab.id) } },
        ]
    }

    /// Fork: a copy of the chat opens in a new tab and comes to the front, as on the Mac.
    /// acpmux's refusal (a Claude chat the Mac started) shows in its own words.
    public func fork(_ id: TabsKitTab.ID) async {
        guard let workspace, let creator, let tab = workspaceTab(id), tab.kind == .agent, pendingTabTitle == nil else { return }
        pendingTabTitle = "Fork"
        defer { pendingTabTitle = nil }
        do {
            let copy = try await creator.backend.forkAgentChat(tab, in: workspace)
            if store.workspace(id: workspaceID)?.tabs.contains(where: { $0.id == copy.id }) != true {
                store.appendTab(copy, to: workspaceID)
            }
            activate(copy.id)
            openedTab = copy.id
        } catch {
            show(error, doing: "fork", tab.title)
        }
    }

    /// Archive: the chat is archived on the Mac (its sidebar's Archived list) and its tab closes.
    public func archive(_ id: TabsKitTab.ID) async {
        guard let workspace, let creator, let tab = workspaceTab(id), tab.kind == .agent else { return }
        do {
            try await creator.backend.archiveAgentChat(tab, in: workspace)
        } catch {
            return show(error, doing: "archive", tab.title)
        }
        let next = store.removeTab(id, from: workspaceID)
        surfaces[id] = nil
        if selectedTabID == id || workspaceTab(selectedTabID ?? "") == nil { selectedTabID = next?.id }
        if self.workspace?.tabs.isEmpty ?? true { exit() }
    }

    // MARK: Saved tab groups (Reopen / Delete Saved Tab Group…)

    /// Reopen Saved Tab Group… or Delete Saved Tab Group…: the chooser that is open, with the
    /// Mac's saved groups and the tab whose pane a reopened group goes to.
    public struct SavedGroupsChooser: Identifiable {
        public let action: SavedTabGroupAction
        public let tab: WorkspaceTab
        public var groups: [SavedTabGroup]
        public var id: String { action.rawValue }
    }

    public var savedGroupsChooser: SavedGroupsChooser?

    /// Reads the Mac's saved groups and opens the chooser (a line instead when it has none).
    public func openSavedGroups(_ action: SavedTabGroupAction, from id: TabsKitTab.ID) async {
        guard let workspace, let creator, let tab = workspaceTab(id) else { return }
        do {
            let groups = try await creator.backend.savedTabGroups(on: workspace.macID)
            if groups.isEmpty { return show("No saved tab groups on \(macName). Pin Group saves one.") }
            savedGroupsChooser = SavedGroupsChooser(action: action, tab: tab, groups: groups)
        } catch {
            savedGroupFailed(error, action)
        }
    }

    /// Reopen Saved Tab Group…: the Mac reopens it in this tab's pane; its tabs arrive with
    /// the Mac's list.
    public func reopenSaved(_ saved: SavedTabGroup, besides id: TabsKitTab.ID) async {
        savedGroupsChooser = nil
        guard let workspace, let creator, let tab = workspaceTab(id) else { return }
        if saved.isOpen { return show(SavedTabGroupAction.alreadyOpen) }
        do {
            try await creator.backend.reopenSavedTabGroup(saved, besides: tab, in: workspace)
            show("Reopened \(saved.displayName).")
            CmuxMobileTheme.standard.haptics.success()
        } catch {
            savedGroupFailed(error, .reopen)
        }
    }

    /// Delete Saved Tab Group…: the record goes on the Mac; an open group stays, unpinned (the
    /// Mac's list says so).
    public func deleteSaved(_ saved: SavedTabGroup) async {
        savedGroupsChooser = nil
        guard let workspace, let creator else { return }
        do {
            try await creator.backend.deleteSavedTabGroup(saved, on: workspace.macID)
            show("Deleted \(saved.displayName).")
        } catch {
            savedGroupFailed(error, .delete)
        }
    }

    private func savedGroupFailed(_ error: any Error, _ action: SavedTabGroupAction) {
        if let error = error as? WorkspaceCreationError, error.isForPerson {
            show(named(error.message))
        } else if TabNotice.cause(of: Self.message(error)) == .gone {
            show(SavedTabGroupAction.gone)
        } else {
            show(TabNotice(action: .group(action.title), macName: macName, reason: Self.message(error)))
        }
        CmuxMobileTheme.standard.haptics.error()
    }

    /// The Mac's palette rows for saved groups, in the page menu (the Mac targets the pane).
    private func savedGroupItems(_ tab: WorkspaceTab) -> [TabsKitMenuItem] {
        guard canEditTabs else { return [] }
        return [
            TabsKitMenuItem(title: SavedTabGroupAction.reopen.title, systemImage: "bookmark.fill") { [weak self] in
                Task { await self?.openSavedGroups(.reopen, from: tab.id) }
            },
            TabsKitMenuItem(title: SavedTabGroupAction.delete.title, systemImage: "trash") { [weak self] in
                Task { await self?.openSavedGroups(.delete, from: tab.id) }
            },
        ]
    }

    /// A refusal: the phone's or the Mac's own sentence when it is written for the person,
    /// else one short line ("Couldn't fork Claude.").
    private func show(_ error: any Error, doing verb: String, _ title: String) {
        if let error = error as? WorkspaceCreationError, error.isForPerson {
            show(named(error.message))
        } else {
            show(TabNotice(action: .other(verb: verb, title: title), macName: macName, reason: Self.message(error)))
        }
        CmuxMobileTheme.standard.haptics.error()
    }

    /// The Mac's tab menu, top rows: Rename Tab…, Pin Tab or Unpin Tab, Duplicate Tab.
    private func editItems(_ tab: WorkspaceTab) -> [TabsKitMenuItem] {
        guard canEditTabs else { return [] }
        return [
            TabsKitMenuItem(title: "Rename Tab…", systemImage: "pencil") { [weak self] in self?.startRename(tab.id) },
            TabsKitMenuItem(title: tab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: tab.isPinned ? "pin.slash" : "pin") { [weak self] in
                Task { await self?.setPinned(tab.id, !tab.isPinned) }
            },
            TabsKitMenuItem(title: "Duplicate Tab", systemImage: "plus.square.on.square") { [weak self] in
                Task { await self?.duplicate(tab.id) }
            },
        ]
    }

    /// The Mac's group section (New Tab Group, Add Tab to Group…, Remove Tab from Group),
    /// then the tab's group itself, whose actions the Mac puts on the group's chip.
    private func groupItems(_ tab: WorkspaceTab) -> [TabsKitMenuItem] {
        guard canEditTabs else { return [] }
        var items: [TabsKitMenuItem] = []
        if let group = tab.group {
            items.append(TabsKitMenuItem(title: TabGroupEdit.remove.title, systemImage: "rectangle.badge.minus") { [weak self] in
                Task { await self?.editGroup(.remove, tab.id) }
            })
            items.append(TabsKitMenuItem(id: "tab-group-actions", title: "Tab Group: \(group.displayName)…", systemImage: "folder") { [weak self] in
                self?.groupActionsTab = tab
            })
        } else if !tab.isPinned {
            items.append(TabsKitMenuItem(title: TabGroupEdit.create.title, systemImage: "rectangle.badge.plus") { [weak self] in
                Task { await self?.editGroup(.create, tab.id) }
            })
            if !groups(besides: tab).isEmpty {
                items.append(TabsKitMenuItem(title: TabGroupEdit.add(group: "").title, systemImage: "rectangle.stack.badge.plus") { [weak self] in
                    self?.addingToGroupTab = tab
                })
            }
        }
        return items
    }

    /// Move Tab to Workspace… (another workspace on this Mac) and Move Tab to New Workspace.
    /// Home's tabs stay in Home: as the Mac (`TabPromotion`), a Home tab's menu leaves out the
    /// promotion Move Tab to New Workspace, and keeps Move Tab to Workspace….
    private func moveItems(_ tab: WorkspaceTab) -> [TabsKitMenuItem] {
        guard canEditTabs else { return [] }
        var items: [TabsKitMenuItem] = []
        if !otherWorkspaces.isEmpty {
            items.append(TabsKitMenuItem(title: "Move Tab to Workspace…", systemImage: "arrow.right.square") { [weak self] in
                self?.movingTab = tab
            })
        }
        if workspace?.isHome == true { return items }
        items.append(TabsKitMenuItem(title: "Move Tab to New Workspace", systemImage: "rectangle.portrait.and.arrow.right") { [weak self] in
            Task { await self?.move(tab.id, to: nil) }
        })
        return items
    }

    /// The card's long-press menu: the Mac's top tab rows and its group rows. TabsKit adds
    /// Close Tab and Close Other Tabs itself; the moves (the Mac's More) are in the page menu,
    /// which has room for them.
    public func cardMenu(for kit: TabsKitTab) -> [[TabsKitMenuItem]] {
        guard let tab = workspaceTab(kit.id) else { return [] }
        return [editItems(tab), groupItems(tab)].filter { !$0.isEmpty }
    }

    public func pageMenu(for kit: TabsKitTab) -> [[TabsKitMenuItem]] {
        guard let workspace, let tab = workspaceTab(kit.id) else { return [] }
        let edit = editItems(tab) + groupItems(tab) + moveItems(tab) + savedGroupItems(tab)
        let close = TabsKitMenuItem(title: "Close Tab", systemImage: "xmark", isDestructive: true) { [weak self] in Task { _ = await self?.close(kit.id) } }
        let leave = TabsKitMenuItem(title: "All Workspaces", systemImage: "square.stack.3d.up") { [weak self] in self?.exit() }
        switch tab.kind {
        case .agent:
            let store = chatStore(tab, workspace)
            let surface = surface(tab.id)
            return [
                [
                    TabsKitMenuItem(title: "Agent Edits", systemImage: "plus.forwardslash.minus",
                                    isEnabled: AgentChatSurface.hasAgentEdits(store)) { surface.openAllChanges(of: store) },
                    TabsKitMenuItem(title: "Files and Artifacts", systemImage: "folder") { surface.showArtifacts = true },
                    TabsKitMenuItem(title: "Copy Session ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = store.summary.id },
                ],
                [
                    TabsKitMenuItem(title: store.subagents.isEmpty ? "Subagents" : "Subagents (\(store.subagents.count))",
                                    systemImage: "person.2.wave.2") { surface.parityRoute = .subagents },
                ] + (store.source.supportsCheckpoints
                    ? [TabsKitMenuItem(title: "Checkpoints", systemImage: "clock.arrow.circlepath") { surface.parityRoute = .checkpoints }]
                    : []) + [
                    TabsKitMenuItem(title: "Continue in…", systemImage: "arrow.triangle.branch") { surface.parityRoute = .handoff },
                ] + chatItems(tab),
                edit,
                [leave],
                [
                    TabsKitMenuItem(title: "Stop Agent", systemImage: "stop.circle", isEnabled: store.isRunning, isDestructive: true) { store.cancel() },
                    close,
                ],
            ].filter { !$0.isEmpty }
        case .terminal:
            let own = terminal.actions(for: tab, in: workspace).map { action in
                TabsKitMenuItem(title: action.title, systemImage: action.systemImage, isEnabled: action.isEnabled,
                                isDestructive: action.isDestructive) { action.perform() }
            }
            let copy = TabsKitMenuItem(title: "Copy Directory", systemImage: "doc.on.doc") { UIPasteboard.general.string = tab.subtitle ?? workspace.directory }
            // The Mac shows Restart Shell Here only on a tab whose shell ended.
            let restart = tab.hasEndedShell && canEditTabs
                ? [TabsKitMenuItem(title: Self.restartShellTitle, systemImage: "arrow.counterclockwise") { [weak self] in
                    Task { await self?.restartShell(tab.id) }
                }] : []
            // Files and Links, Paste, Clear | Copy Directory | Close Tab: no
            // "All Workspaces" (Back leaves the workspace; design/terminal P1).
            return [restart, own, [copy], edit, [close]].filter { !$0.isEmpty }
        case .browser:
            let model = browser(tab)
            return [
                [
                    TabsKitMenuItem(title: "Copy Link", systemImage: "link", isEnabled: model.url != nil) { UIPasteboard.general.url = model.url },
                    TabsKitMenuItem(title: "Reload", systemImage: "arrow.clockwise") { model.reloadOrStop() },
                ],
                edit,
                [leave],
                [close],
            ].filter { !$0.isEmpty }
        case .simulator:
            let model = simulator(tab)
            return [
                [
                    TabsKitMenuItem(title: "Home", systemImage: "circle", isEnabled: model != nil) { model?.pressButton("home") },
                    TabsKitMenuItem(title: "Lock", systemImage: "lock", isEnabled: model != nil) { model?.pressButton("lock") },
                ],
                edit,
                [leave],
                [close],
            ].filter { !$0.isEmpty }
        }
    }
}

/// A tab's live page, by kind.
struct WorkspaceTabPage: View {
    let source: WorkspaceTabsSource
    let tabID: String
    let context: TabsKitContentContext

    var body: some View {
        if let workspace = source.workspace, let tab = workspace.tabs.first(where: { $0.id == tabID }) {
            page(tab, workspace)
                .onAppear {
                    source.remember(context.safeAreaInsets, pageHeight: context.pageSize.height)
                    source.pageAppeared(tabID)
                }
        }
    }

    @ViewBuilder
    private func page(_ tab: WorkspaceTab, _ workspace: Workspace) -> some View {
        let insets = context.safeAreaInsets
        switch tab.kind {
        case .agent:
            let surface = source.surface(tab.id)
            AgentChatTranscript(
                store: source.chatStore(tab, workspace), surface: surface,
                topInset: insets.top + 8,
                onUserScroll: { context.reportScroll(fingerDelta: $0) }
            )
            .background(Color.cmuxMobileBackground)
            // A page built during a zoom or swipe is laid out before its
            // composer is measured; once it settles, a following chat lands
            // on its newest turn above the composer.
            .onChange(of: context.isInteractive) { _, interactive in
                if interactive, surface.following { surface.scrollToBottom(animated: false) }
            }
        case .terminal:
            source.terminal.page(for: tab, in: workspace, context: terminalContext)
                .overlay {
                    // The Mac's dead-tab overlay: the shell ended; its button restarts it.
                    if tab.hasEndedShell {
                        VStack(spacing: 12) {
                            Text("The shell ended.").font(.headline)
                            Button(WorkspaceTabsSource.restartShellTitle, systemImage: "arrow.counterclockwise") {
                                Task { await source.restartShell(tab.id) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!source.canEditTabs)
                        }
                        .padding(20)
                        .background(.regularMaterial, in: .rect(cornerRadius: 16))
                    }
                }
        case .browser:
            if let model = source.browser(tab) as? StreamedBrowserModel {
                StreamedBrowserPage(model: model, insets: insets, reportScroll: { context.reportScroll(fingerDelta: $0) })
            } else {
                BrowserPage(model: source.localBrowser(tab), insets: insets, isZoomGestureActive: context.isZoomGestureActive,
                            reportScroll: { context.reportScroll(fingerDelta: $0) })
            }
        case .simulator:
            if let model = source.simulator(tab) {
                StreamedSimulatorPage(model: model, insets: insets)
            } else {
                Text("Connect to \(source.macName) to see this simulator.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
    }

    /// Above the floating composer (which rides the toolbar or the keyboard).
    static func bottomInset(surface: AgentChatSurface, insets: EdgeInsets, pageHeight: CGFloat) -> CGFloat {
        guard let top = surface.bottomStackTop, top > 0, pageHeight > 0 else { return insets.bottom + 72 }
        return max(insets.bottom, pageHeight - top) + 12
    }

    private var terminalContext: TerminalTabContext {
        let context = context
        let tabID = tabID
        return TerminalTabContext(safeAreaInsets: context.safeAreaInsets, isInteractive: context.isInteractive,
                                  isZoomGestureActive: context.isZoomGestureActive,
                                  reportScroll: { context.reportScroll(fingerDelta: $0) },
                                  openLink: { [weak source] url in Task { await source?.openLink(url, fromTab: tabID) } })
    }
}

/// The row above the toolbar: the agent's composer (or permission bar), the
/// terminal's key bar. Browser tabs have none.
struct WorkspaceTabAccessory: View {
    let source: WorkspaceTabsSource
    let tabID: String
    let context: TabsKitContentContext

    var body: some View {
        row.modifier(AccessoryFloor(context: context))
    }

    @ViewBuilder private var row: some View {
        if let workspace = source.workspace, let tab = workspace.tabs.first(where: { $0.id == tabID }) {
            switch tab.kind {
            case .agent:
                AgentChatBottomStack(store: source.chatStore(tab, workspace), surface: source.surface(tab.id))
            case .terminal:
                let context = context
                source.terminal.accessory(for: tab, in: workspace, context: TerminalTabContext(
                    safeAreaInsets: context.safeAreaInsets, isInteractive: context.isInteractive,
                    isZoomGestureActive: context.isZoomGestureActive, reportScroll: { context.reportScroll(fingerDelta: $0) }))
            case .browser:
                EmptyView()
            case .simulator:
                if let model = source.simulator(tab) { StreamedSimulatorAccessory(model: model) }
            }
        }
    }
}

/// Keeps the accessory row from going below its resting place above the
/// expanded toolbar. TabsKit places the row at the keyboard's height while
/// the keyboard is up; an interactive dismissal drags the keyboard under the
/// toolbar before it reports 0, so the row followed it down, then jumped
/// back up. This lifts the row by however far it would sink, as a render
/// effect (no layout feedback). A collapsed toolbar rests lower, so the
/// floor applies only with the toolbar expanded.
struct AccessoryFloor: ViewModifier {
    let context: TabsKitContentContext

    func body(content: Content) -> some View {
        let floor = context.pageSize.height - context.safeAreaInsets.bottom
        let applies = !context.isToolbarCollapsed && floor > 0
        content.visualEffect { effect, proxy in
            effect.offset(y: applies ? -Self.overshoot(maxY: proxy.frame(in: .global).maxY, floor: floor) : 0)
        }
    }

    /// Points the row's bottom sits below the floor (0 when above it).
    nonisolated static func overshoot(maxY: CGFloat, floor: CGFloat) -> CGFloat {
        max(0, maxY - floor)
    }
}

/// A tab's card in the grid: the page as it looks at rest.
struct WorkspaceTabCard: View {
    let source: WorkspaceTabsSource
    let tabID: String
    let insets: EdgeInsets

    var body: some View {
        if let workspace = source.workspace, let tab = workspace.tabs.first(where: { $0.id == tabID }) {
            preview(tab, workspace)
                // The card shows the top of the page, scaled down: the chip sits there, sized
                // in page points so it reads like the card's title.
                .overlay(alignment: .topLeading) {
                    if let group = tab.group { TabGroupChip(group: group).padding(.leading, 16).padding(.top, 14) }
                }
        } else {
            Color.cmuxMobileBackground
        }
    }

    @ViewBuilder
    private func preview(_ tab: WorkspaceTab, _ workspace: Workspace) -> some View {
            switch tab.kind {
            case .agent:
                let surface = source.surface(tab.id)
                AgentChatPreview(store: source.chatStore(tab, workspace), topInset: insets.top + 8,
                                 bottomInset: WorkspaceTabPage.bottomInset(surface: surface, insets: insets, pageHeight: source.pageHeight))
            case .terminal:
                source.terminal.card(for: tab, in: workspace)
            case .browser:
                if let model = source.browser(tab) as? StreamedBrowserModel {
                    StreamedBrowserCard(model: model)
                } else {
                    BrowserCard(model: source.localBrowser(tab), insets: insets)
                }
            case .simulator:
                if let model = source.simulator(tab) {
                    StreamedBrowserCard(model: model, placeholder: "iphone", fit: true)
                } else {
                    Image(systemName: "iphone").font(.system(size: 72, weight: .light)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
    }
}

/// A tab group's name on its member's card, in the group's color (the Mac's group chip).
struct TabGroupChip: View {
    let group: WorkspaceTab.TabGroupRef

    var body: some View {
        Text(group.displayName)
            .font(.system(size: 26, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Self.color(group.color), in: .capsule)
            .accessibilityLabel("In tab group \(group.displayName)")
    }

    /// The nine Mac group colors, or a custom `#RRGGBB`.
    static func color(_ token: String) -> Color {
        switch token {
        case "blue": return Color.blue
        case "red": return Color.red
        case "yellow": return Color.yellow
        case "green": return Color.green
        case "pink": return Color.pink
        case "purple": return Color.purple
        case "cyan": return Color.cyan
        case "orange": return Color.orange
        default:
            if token.hasPrefix("#"), token.count == 7, let value = UInt32(token.dropFirst(), radix: 16) {
                return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
            }
            return Color.gray
        }
    }
}
#endif
