import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextWakeups
import os

/// The App's side of ``CEFChatRendererRecycle``: after each renderer check (`CEFPageRendererGC`), a chat renderer
/// past its bound whose pages are all spares or idle chats, while the person is away, is emptied and its shown
/// chats are built again in a fresh process.
///
/// 1. Every chat in it is captured as a hidden idle chat's release captures it (``AgentPageHibernation``), with
///    no first frame required; the shown chats keep their frame. Any page kept (unsaved sends, no answer) ends it.
/// 2. In one main-actor turn the spare pool holds empty, the next Cmd-N's reservation pauses and its page goes,
///    the closed chats kept for Reopen Closed are torn down, and every chat lets go of its page (its tab keeps its
///    session and wake state). The shown panes draw the chat's frame meanwhile.
/// 3. Once the old renderer exited (at most ``AgentPageRetirer/delay`` plus ``CEFChatRendererRecycle/exitLimit``),
///    each pane still selecting its chat shows it again through the normal show path, and the pools refill.
/// 4. ``settleDelay`` later one notice in `app.hibernation` gives the resident size before and after.
///
/// Made only when `CMUX_NEXT_CHAT_RENDERER_RECYCLE=1` (``AppServices/startHibernation(settings:)``).
@MainActor
final class ChatRendererRecycler {
    /// How long after the rebuild the fresh renderer's resident size is read (the bench's chats draw within 2 s).
    static let settleDelay: Duration = .seconds(10)

    private weak var services: AppServices?
    private var state = CEFChatRendererRecycle()
    private var running = false
    private let settle = DemandTimer(owner: "ChatRendererRecycler.settle")
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")
    private lazy var input = WindowServerInputEvents()

    init(services: AppServices) {
        self.services = services
    }

    /// One renderer check ended: recycles the first chat renderer that is due and may go.
    func check() async {
        guard !running, let services, let agentPages = services.cache.hibernation?.agentPages, let tabs = services.madeAgentTabs else { return }
        let cef = services.cache.cef
        let all = cef.rendererPages
        let chatRenderers = Set(all.filter { $0.origin == CEFChatRendererRecycle.chatOrigin }.compactMap(\.rendererClients.first))
        guard !chatRenderers.isEmpty else { return }
        running = true
        defer { running = false }
        for renderer in chatRenderers.sorted() {
            guard let sample = await ChromiumHelperProcess.renderer(client: renderer),
                  state.isDue(renderer: renderer, resident: sample.resident, now: .now, live: chatRenderers) else { continue }
            let pages = cef.rendererPages.filter { $0.rendererClients.first == renderer }
            switch CEFChatRendererRecycle.decide(classify(pages, tabs: tabs, agentPages: agentPages), personIdle: personIdle, shuttingDown: shuttingDown) {
            case .skip(let why):
                logger.info("chat renderer \(renderer) at \(sample.resident >> 20) MB not recycled: \(why, privacy: .public)")
            case .recycle(let release, let show):
                await recycle(renderer: renderer, pid: sample.pid, before: sample.resident, release: release, show: show, tabs: tabs, agentPages: agentPages)
            }
            return
        }
    }

    private var personIdle: Bool {
        CEFChatRendererRecycle.personIdle(secondsSinceInput: input.secondsSinceLastInput(), appActive: NSApp.isActive)
    }

    private var shuttingDown: Bool { services?.quit.isQuitting != false || services?.cache.cef.isShuttingDown != false }

    /// What each page of the renderer is to the recycle, by browser id.
    private func classify(_ pages: [CEFRendererPage], tabs: AgentTabStore, agentPages: AgentPageHibernation) -> [CEFChatRendererRecycle.Page] {
        guard let services else { return [] }
        let duplicates = AgentTabMap<AgentPaneView>.duplicateIDs(tabs.views.entries.map(\.key))
        var byBrowser: [Int32: CEFChatRendererRecycle.Page] = [:]
        for (key, view) in tabs.views.entries {
            guard let browser = Self.browserID(of: view) else { continue }
            let storage = key.relaunchStorageKey(duplicateIDs: duplicates)
            let newTab = view.model.newTab != nil || tabs.newTabPages[key] != nil
            let reserved = tabs.tabStores[key] === services.daemon.store && tabs.tabStores[key]?.reservedWorkspace?.tabKey == key.key && view.isUntouchedNewTab
            byBrowser[browser] = CEFChatRendererRecycle.tabPage(
                key: storage, newTab: newTab, reservedUntouched: reserved,
                exemption: newTab ? nil : agentPages.recycleExemption(storage), shown: AgentPaneHibernationCapture(view: view).isOnScreen)
        }
        for view in services.newTabSpares.spares + tabs.retirer.keptPages.map({ $0.view }) {
            if let browser = Self.browserID(of: view) { byBrowser[browser] = .spare }
        }
        return pages.map { page in
            if page.origin != CEFChatRendererRecycle.chatOrigin { return .keeps("a page of \(page.origin)") }
            return byBrowser[page.browserID] ?? .keeps("a page no tab or pool holds")
        }
    }

    private static func browserID(of view: AgentPaneView) -> Int32? { (view.chromiumPage as? CEFPageChromiumPage)?.tab.browserID }

    private func recycle(renderer: Int32, pid: Int32, before: Int, release: [String], show: [String],
                         tabs: AgentTabStore, agentPages: AgentPageHibernation) async {
        // 1. Capture every chat; one kept ends the recycle.
        var captured: [(key: String, page: AgentPaneView, wake: AgentPaneWakeState?, frame: CGImage?, size: NSSize)] = []
        var kept: String?
        for key in release {
            guard let capture = await agentPages.captureForRecycle(key, frame: show.contains(key)) else { kept = "\(key) went"; break }
            captured.append((key, capture.page, capture.wake, capture.frame, capture.size))
            if let reason = capture.kept { kept = "\(key) kept: \(reason)"; break }
            // A shown chat with no frame would leave its pane empty until the rebuild.
            if show.contains(key), capture.frame == nil { kept = "\(key) has no frame"; break }
        }
        // The captures awaited: everything is read again.
        if kept == nil, !personIdle { kept = "the person came back" }
        if kept == nil, shuttingDown { kept = "shutting down" }
        if kept == nil, let moved = captured.first(where: { agentPages.hibernationPage($0.key) !== $0.page || agentPages.recycleExemption($0.key) != nil }) { kept = "\(moved.key) changed" }
        guard kept == nil, let services else {
            for capture in captured { agentPages.dropReleasedFrame(capture.key) }
            agentPages.replan() // the captures thawed them
            state.aborted(at: .now)
            return logger.info("chat renderer \(renderer) at \(before >> 20) MB not recycled: \(kept ?? "", privacy: .public)")
        }

        // 2. One turn: nothing makes a page in the old renderer, and every page in it goes.
        let panes: [(tab: String, pane: PaneController, frame: CGImage?, size: NSSize)] = captured.compactMap { capture in
            let tab = AgentTabKey(relaunchStorageKey: capture.key).key
            guard show.contains(capture.key), let pane = services.cache.presenter(of: tab) as? PaneController else { return nil }
            return (tab, pane, capture.frame, capture.size)
        }
        let store = services.daemon.store
        let wasPaused = store.reservationPaused
        services.newTabSpares.holdEmpty()
        store.reservationPaused = true
        services.windows.controllers.forEach { $0.reservedContent.drop() }
        tabs.releaseReservedWorkspace(on: store, .recycle)
        tabs.retirer.dropKept()
        var released = 0
        for capture in captured where agentPages.letGoForRecycle(capture.key, page: capture.page, wake: capture.wake) { released += 1 }
        for shown in panes where shown.pane.currentTabKey == nil {
            shown.pane.leftEmptyByMove = false // a first visit during the wait would build the page in the old renderer
            guard let frame = shown.frame else { continue }
            shown.pane.view.showLaunchImage(NSImage(cgImage: frame, size: shown.size))
            shown.pane.view.launchImageMayClear = { false } // the rebuild's own frame replaces it
        }

        // 3. The old renderer exits once its last page closed (the retirer closes them after its delay).
        let exited = await ChromiumHelperProcess.waitForExit(pid, limit: AgentPageRetirer.delay + CEFChatRendererRecycle.exitLimit)
        for shown in panes where shown.pane.currentTabKey == nil {
            if shown.pane.stripModel.selectedID?.rawValue == shown.tab, !shuttingDown {
                services.presentation.showNow(shown.pane)
            } else {
                shown.pane.view.clearLaunchImage()
            }
        }
        services.newTabSpares.endHold()
        store.reservationPaused = wasPaused
        if !wasPaused { services.windows.controllers.forEach { $0.reservedContent.fill() } }
        state.recycled(at: .now)

        // 4. The fresh renderer's size once its chats drew.
        let shownCount = panes.count
        settle.schedule(after: Self.settleDelay) { @MainActor [weak self] in
            await self?.settled(before: before, released: released, shown: shownCount, exited: exited)
        }
    }

    private func settled(before: Int, released: Int, shown: Int, exited: Bool) async {
        guard let cef = services?.cache.cef,
              let renderer = cef.rendererPages.first(where: { $0.origin == CEFChatRendererRecycle.chatOrigin })?.rendererClients.first,
              let sample = await ChromiumHelperProcess.renderer(client: renderer) else {
            return logger.notice("chat renderer recycled before=\(before >> 20) MB after=none released=\(released) shown=\(shown) exited=\(exited)")
        }
        state.settled(renderer: renderer, resident: sample.resident)
        logger.notice("chat renderer recycled before=\(before >> 20) MB after=\(sample.resident >> 20) MB released=\(released) shown=\(shown) exited=\(exited)")
    }
}
