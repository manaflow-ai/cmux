#if os(iOS)
import CmuxMobileLive
import CmuxMobileModel
import CmuxMobileTerminal
import CmuxMobileTransport
import CmuxMobileWorkspaces
import SwiftUI
import UIKit
import Observation
import OSLog

private let warmLog = Logger(subsystem: "dev.cmux.mobile", category: "terminal")

/// Plugs CmuxMobileTerminal into the workspace tabs in its embedded chrome: TabsKit
/// owns the status bar area and the toolbar, the terminal's actions go into
/// the page menu, and the grid card is a snapshot of the page (no second live
/// surface). One host (model + controller) per tab. The `warmLimit` most
/// recently shown tabs keep their surface and attached session, so switching
/// between them needs no reattach and no new surface; an older one is cooled
/// (session detached, surface released) and keeps its last frame, which its
/// page shows at once, dimmed, while it reattaches.
@MainActor
final class GhosttyTerminalTabContent: TerminalTabContent {
    /// Live Ghostty surfaces (and Mac attaches) kept across tab switches.
    static let warmLimit = 4
    private var hosts: [String: TerminalTabHost] = [:]
    private var warm = TerminalWarmSet<String>(limit: GhosttyTerminalTabContent.warmLimit)
    /// Cooled tabs' pages as last seen.
    private var lastFrames: [TerminalFrameKey: UIImage] = [:]
    /// The frame identity captured when each live host was built. This keeps
    /// a frame tied to the account that owned it even if auth changes later.
    private var hostFrameKeys: [String: TerminalFrameKey] = [:]
    private var frameLifecycle = TerminalFrameLifecycle()
    /// Tabs whose host runs on a live session (the rest show the connecting
    /// placeholder, or the mock in DEBUG mock mode).
    private var liveTabs: Set<String> = []
    private var workspaceOwner: [String: String] = [:]
    /// Each host's Mac. Tab ids (`s<surface>`) repeat across Macs: a tab of
    /// another Mac with the same id gets its own host, never this one.
    private var hostMacs: [String: String] = [:]
    /// Per tab: "Reattaching…" in the title pill after a slow reattach (P5),
    /// fed from the host model's `connectionState` while the tab has a host.
    private var indicators: [String: ReattachIndicator<ContinuousClock>] = [:]
    /// What each tab's page and card show; a placeholder host is swapped for
    /// the live one in place, so a page already on screen attaches (R1-0).
    private var slots: [String: TerminalTabSlot] = [:]
    /// Tabs on a placeholder session and where they live, offered their live
    /// session on every live-data change (`liveDataChanged`).
    private var upgrade = TerminalTabUpgrade()
    private var placeholderTabs: [String: (tab: WorkspaceTab, workspace: Workspace)] = [:]
    /// Last frames kept across launches.
    var frameStore: TerminalFrameStore? = .standard
    /// The signed-in account that owns the linked Macs. Unscoped frames are
    /// never loaded or saved when auth has not resolved to a stable ID.
    var accountUserIDProvider: (@MainActor () -> String?)?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    /// The app is in the foreground: only then does a shown terminal size
    /// its Mac terminal (PROTOCOL.md, "Terminal size claims").
    private var appActive = UIApplication.shared.applicationState != .background

    init() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The background (or the lock screen) releases every
                // terminal's size at once. A short background task keeps the
                // app running for the releases to reach the Mac (bounded:
                // the Mac's size lease covers a release that never lands).
                let release = SizeReleaseBackgroundTask()
                release.begin()
                self?.setAppActive(false)
                self?.saveFrames()
                release.endAfter(.seconds(2))
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppActive(true) }
        }
    }

    private func setAppActive(_ active: Bool) {
        appActive = active
        for host in hosts.values { host.model.setAppActive(active) }
    }

    private func frameKey(surfaceID: String, macID: String?) -> TerminalFrameKey? {
        guard let accountID = accountUserIDProvider?(), !accountID.isEmpty,
              let macID, !macID.isEmpty else { return nil }
        return TerminalFrameKey(accountID: accountID, macID: macID, surfaceID: surfaceID)
    }

    private func frameKey(for tab: WorkspaceTab, in workspace: Workspace) -> TerminalFrameKey? {
        frameKey(surfaceID: tab.id, macID: workspace.macID)
    }

    /// Going to the background: each live page's frame goes to disk, so a
    /// later cold launch restoring the tab shows it at once.
    private func saveFrames() {
        guard let frameStore else { return }
        for (id, host) in hosts where liveTabs.contains(id) {
            guard let key = hostFrameKeys[id] else { continue }
            host.model.captureSnapshot()
            if let data = host.model.frameForSaving()?.jpegData(compressionQuality: 0.7) { frameStore.save(data, for: key) }
        }
    }

    /// The tab's slot, made on first read (not observed state itself).
    private func slot(for id: String, host: TerminalTabHost) -> TerminalTabSlot {
        if let slot = slots[id] {
            if slot.host !== host { slot.host = host }
            return slot
        }
        let slot = TerminalTabSlot(host: host)
        slots[id] = slot
        return slot
    }

    /// Live data changed (the workspace tree, a Mac's data): tabs still on a
    /// placeholder get their live session now, in the page already shown.
    func liveDataChanged() {
        guard sessionProvider != nil else { return }
        for id in upgrade.upgradable(hasLiveSession: { [weak self] id in self?.canGoLive(id) ?? false }) {
            guard let place = placeholderTabs[id] else { continue }
            // The workspace as it is now (tabs opened or closed since).
            let workspace = workspaceLookup?(place.workspace.id) ?? place.workspace
            let tab = workspace.tabs.first { $0.id == id } ?? place.tab
            let host = host(for: tab, in: workspace)
            if liveTabs.contains(id) {
                _ = slot(for: id, host: host)
                warmLog.info("terminal tab \(id, privacy: .public) moved from the placeholder to its live session")
            }
        }
    }

    /// The current copy of a workspace (its tabs), for `liveDataChanged`.
    var workspaceLookup: (@MainActor (String) -> Workspace?)?

    /// Whether the tab would get a live session now (the tree lists its surface).
    var hasLiveSession: (@MainActor (_ tabID: String, _ macID: String?) -> Bool)?

    private func canGoLive(_ id: String) -> Bool {
        hasLiveSession?(id, placeholderTabs[id]?.workspace.macID) ?? false
    }
    private var feeds: [String: Task<Void, Never>] = [:]
    /// Live mode: a session on the Mac for a terminal tab (a daemon surface),
    /// or nil while there is none yet (the tab then shows "Connecting…").
    var reconnect: (@MainActor (String) -> Void)?
    var sessionProvider: (@MainActor (WorkspaceTab, _ macID: String) -> (any TerminalSession)?)?
    /// Live mode: the Mac's screen as text for a tab's grid card (D5).
    var screenTextProvider: (@MainActor (WorkspaceTab, _ macID: String?) async -> String?)?
    /// When each card's screen text is asked for.
    private var screenTextRefresh = TerminalCardScreenRefresh()
    /// Live mode: Files and Links previews from the Mac.
    var artifactSourceProvider: (@MainActor (WorkspaceTab, _ macID: String) -> (any ArtifactSource)?)?
    /// Live mode: uploads a terminal attachment to the Mac, returning its path there.
    var uploaderProvider: (@MainActor (WorkspaceTab, _ macID: String) -> (@MainActor (LinkUpload.Payload, String) async throws -> String)?)?
    /// DEBUG mock mode (Settings → Developer → Mock): tabs with no live
    /// session run the scripted mock. Ignored outside DEBUG builds.
    var mockDataEnabled = false
    /// The workspace's Mac, for the connecting placeholder's label.
    var macName: (@MainActor (Workspace) -> String?)?
    /// Opens Connected Devices for a live terminal of a Mac (its session, its Mac).
    var showConnectedDevices: (@MainActor (DaemonTerminalSession, _ macID: String) -> Void)?

    private func host(for tab: WorkspaceTab, in workspace: Workspace) -> TerminalTabHost {
        let key = frameKey(for: tab, in: workspace)
        // Another Mac's tab with the same id: its host (and its attach) goes, and
        // this tab builds its own on its own Mac.
        if hosts[tab.id] != nil, let owner = hostMacs[tab.id], owner != workspace.macID {
            warmLog.info("terminal tab \(tab.id, privacy: .public) now shows another Mac's tab: new host")
            release(tab.id)
        }
        if hosts[tab.id] != nil, hostFrameKeys[tab.id]?.accountID != key?.accountID {
            warmLog.info("terminal tab \(tab.id, privacy: .public) changed account: new host")
            release(tab.id)
        }
        // A placeholder (or mock) host built before live data arrived (no
        // coordinator or no tree yet) is replaced once the tab has a live session.
        if let host = hosts[tab.id], liveTabs.contains(tab.id) || sessionProvider == nil { return host }
        // Closed tabs release their surface.
        let open = Set(workspace.tabs.map(\.id))
        for (id, owner) in workspaceOwner where owner == workspace.id && !open.contains(id) {
            // Its Mac attach goes too: a closed tab's session kept waiting to
            // reattach after the next drop (V5-5).
            release(id)
            slots[id] = nil
            cardViews[id] = nil
        }
        let live = sessionProvider?(tab, workspace.macID)
        if let host = hosts[tab.id], live == nil { return host }
        if live != nil { liveTabs.insert(tab.id) }
        // A placeholder replaced by the live session: its frame carries over,
        // and it stops.
        let previous = hosts[tab.id]
        previous?.model.session.stop()
        // A live tab never builds the mock: without a session it shows the
        // honest connecting placeholder (TerminalSessionChoice).
        let mock = mockDataEnabled && live == nil && sessionProvider == nil
        let session = TerminalSessionChoice.session(live: live, mockDataEnabled: mock, macName: macName?(workspace), programName: tab.title)
        let artifacts = live == nil ? nil : artifactSourceProvider?(tab, workspace.macID)
        let model = TerminalModel(
            session: session,
            artifactSource: artifacts ?? TerminalSessionChoice.fallbackArtifactSource(mockDataEnabled: mock),
            title: tab.title
        )
        model.reconnect = { [weak self, weak session] in
            self?.reconnect?(workspace.macID)
            (session as? DaemonTerminalSession)?.reconnect()
            self?.liveDataChanged()
        }
        model.uploader = live == nil ? nil : uploaderProvider?(tab, workspace.macID)
        // The page shown already keeps opening links where it did (R1-0 swaps the host in place).
        model.linkOpener = previous?.model.linkOpener
        var frame = key.flatMap { lastFrames.removeValue(forKey: $0) } ?? previous.flatMap { $0.model.snapshot ?? $0.model.coldFrame }
        if frame == nil, let key, let data = frameStore?.load(key) { frame = UIImage(data: data) }
        model.restoreLastFrame(frame)
        if live != nil, let frameStore, let key {
            // The next cold launch shows what was on screen last (R2-5), not
            // the frame from the last time the app went to the background.
            model.frameSaver = {
                let ticket = frameStore.ticket(for: key)
                return { image in
                    if let data = image.jpegData(compressionQuality: 0.7) { frameStore.save(data, for: key, ticket: ticket) }
                }
            }
        }
        model.setAppActive(appActive)
        let host = TerminalTabHost(model: model)
        hosts[tab.id] = host
        hostFrameKeys[tab.id] = key
        frameLifecycle.hostBuilt(tabID: tab.id)
        upgrade.built(tabID: tab.id, workspaceID: workspace.id, live: live != nil)
        placeholderTabs[tab.id] = live == nil ? (tab, workspace) : nil
        if let slot = slots[tab.id] { slot.host = host }
        watchReattach(tab.id, model: model)
        workspaceOwner[tab.id] = workspace.id
        hostMacs[tab.id] = workspace.macID
        return host
    }

    /// Drops a tab's host: its Mac attach stops, its frames go.
    private func release(_ id: String) {
        let key = hostFrameKeys.removeValue(forKey: id)
        hosts.removeValue(forKey: id)?.model.session.stop()
        cardViews[id] = nil
        stopWatching(id)
        indicators[id] = nil
        workspaceOwner[id] = nil
        hostMacs[id] = nil
        liveTabs.remove(id)
        warm.remove(id)
        frameLifecycle.release(tabID: id, hostFrameKey: key) { frameKey in
            lastFrames[frameKey] = nil
            frameStore?.remove(frameKey)
        }
        upgrade.removed(tabID: id)
        placeholderTabs[id] = nil
    }

    /// Tabs last shown with an ended shell (``page(for:in:context:)``).
    private var endedShells: Set<String> = []

    /// Drops every host (another account or live data stopped).
    func reset() {
        endedShells = []
        for id in Array(feeds.keys) { stopWatching(id) }
        indicators = [:]
        // Each session releases its size on the Mac before its channel closes.
        for host in hosts.values { host.model.session.stop() }
        hosts = [:]
        slots = [:]
        cardViews = [:]
        upgrade.reset()
        placeholderTabs = [:]
        workspaceOwner = [:]
        hostMacs = [:]
        hostFrameKeys = [:]
        frameLifecycle.reset()
        liveTabs = []
        warm = TerminalWarmSet(limit: Self.warmLimit)
        lastFrames = [:]
    }

    func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView {
        // Restart Shell Here keeps the tab id: its attach to the dead shell ended for good,
        // so a tab that is live again gets a fresh host (and a fresh attach).
        if tab.hasEndedShell {
            endedShells.insert(tab.id)
        } else if endedShells.remove(tab.id) != nil {
            cool(tab.id)
        }
        let host = host(for: tab, in: workspace)
        for id in warm.touch(tab.id) { cool(id) }
        let slot = slot(for: tab.id, host: host)
        // A tapped web link opens beside the terminal, in this workspace (the Mac's Cmd-click).
        host.model.linkOpener = context.openLink
        return AnyView(TerminalTabSlotPage(slot: slot, insets: context.safeAreaInsets, isInteractive: context.isInteractive))
    }

    /// Releases a tab that fell out of the warm set: its Mac attach and its
    /// Ghostty surface go, its last frame stays for the card and for the page
    /// when it is shown again (a new host, attached in the background).
    private func cool(_ id: String) {
        guard let host = hosts.removeValue(forKey: id) else { return }
        let key = hostFrameKeys.removeValue(forKey: id)
        if let key { frameLifecycle.cooled(tabID: id, frameKey: key) }
        if let frame = host.model.snapshot {
            if let key {
                lastFrames[key] = frame
                if let data = (host.model.frameForSaving() ?? frame).jpegData(compressionQuality: 0.7) { frameStore?.save(data, for: key) }
            }
        }
        slots[id] = nil
        cardViews[id] = nil
        upgrade.removed(tabID: id)
        placeholderTabs[id] = nil
        host.model.session.stop()
        stopWatching(id)
        liveTabs.remove(id)
        let frameState = key.flatMap { self.lastFrames[$0] } == nil ? "none" : "kept"
        warmLog.info("terminal tab \(id, privacy: .public) cooled (warm set of \(Self.warmLimit, privacy: .public)), last frame \(frameState, privacy: .public)")
    }

    // MARK: Reattach indicator (design/terminal P5)

    /// The tab's indicator, made on first read and kept, so the tab list
    /// that read it observes it before the tab's host exists. Not observed
    /// state itself: making one during a view update notifies nothing.
    private func indicator(_ id: String) -> ReattachIndicator<ContinuousClock> {
        if let indicator = indicators[id] { return indicator }
        let indicator = ReattachIndicator()
        indicators[id] = indicator
        return indicator
    }

    /// Feeds the tab's indicator from its host model's connection state.
    private func watchReattach(_ id: String, model: TerminalModel) {
        stopWatching(id)
        let indicator = indicator(id)
        feeds[id] = Task { [weak indicator, model] in
            for await state in Observations({ model.connectionState }) {
                guard let indicator else { return }
                if case .offline = state { indicator.update(offline: true); continue }
                indicator.update(offline: false)
                if case .reattaching = state { indicator.update(reattaching: true) } else { indicator.update(reattaching: false) }
            }
        }
    }

    /// The host went away (closed or cooled). A cooled tab's next host feeds
    /// the same indicator again.
    private func stopWatching(_ id: String) {
        feeds.removeValue(forKey: id)?.cancel()
        indicators[id]?.cancel()
    }

    /// A read (no host is created): the tab's pill says "Reattaching…" while
    /// its reattach has lasted 400 ms or more.
    func statusSubtitle(for tab: WorkspaceTab) -> String? {
        let indicator = indicator(tab.id)
        if indicator.isOffline { return "Mac offline" }
        return indicator.isShown ? "Reattaching…" : nil
    }

    func focusInput(for tab: WorkspaceTab, in workspace: Workspace) {
        host(for: tab, in: workspace).model.focusComposer()
    }

    /// Each tab's card view, made once per slot: a card body is a lookup.
    private var cardViews: [String: (slot: ObjectIdentifier, view: AnyView)] = [:]

    func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView {
        if let slot = slots[tab.id], let cached = cardViews[tab.id], cached.slot == ObjectIdentifier(slot),
           hostMacs[tab.id] == workspace.macID { return cached.view }
        // A card shown before its tab was prepared (or after its slot was
        // cooled): its host and slot are made now, once.
        let host = host(for: tab, in: workspace)
        let slot = slot(for: tab.id, host: host)
        // A new host (first card, or after a cool or a Mac swap) asks for the
        // Mac's screen after this update, as `prepareCard` does.
        Task { @MainActor [weak self, weak model = host.model] in
            guard let self, let model else { return }
            self.refreshScreenText(for: tab, model: model)
        }
        return cardView(tab.id, slot: slot)
    }

    func prepareCard(for tab: WorkspaceTab, in workspace: Workspace) {
        let host = host(for: tab, in: workspace)
        _ = cardView(tab.id, slot: slot(for: tab.id, host: host))
        refreshScreenText(for: tab, model: host.model)
    }

    private func cardView(_ id: String, slot: TerminalTabSlot) -> AnyView {
        if let cached = cardViews[id], cached.slot == ObjectIdentifier(slot) { return cached.view }
        let view = AnyView(TerminalTabSlotCard(slot: slot, insets: EdgeInsets(top: 62, leading: 0, bottom: 98, trailing: 0)))
        cardViews[id] = (ObjectIdentifier(slot), view)
        return view
    }

    /// A tab not opened in this launch shows the Mac's screen in its card
    /// (D5): asked for when the card is built (at most every 3 s per tab),
    /// whenever the grid opens, and again after a read that brought nothing
    /// (`TerminalCardScreenRefresh`). Until it arrives the card's saved frame
    /// is drawn as not current (T-TABS-01).
    /// `live`: the grid's own refresh (D6), which also asks for a started
    /// tab whose page is off screen, at the grid's shorter interval.
    private func refreshScreenText(for tab: WorkspaceTab, model: TerminalModel, gridOpening: Bool = false, live: Bool = false) {
        guard let provider = screenTextProvider, live || !model.pageStarted,
              let request = screenTextRefresh.begin(tab.id, now: Date(), gridOpening: gridOpening,
                                                    interval: live ? TerminalCardLiveRefresh.screenTextInterval : TerminalCardScreenRefresh.interval)
        else { return }
        let macID = hostMacs[tab.id]
        Task { @MainActor [weak self, weak model] in
            let text = await provider(tab, macID)
            guard let self else { return }
            guard let text else {
                self.screenTextRefresh.failed(tab.id, request: request)
                return
            }
            // A slower older reply never replaces a newer card text (A6).
            guard self.screenTextRefresh.finished(tab.id, request: request) else { return }
            guard let model, live || !model.pageStarted else { return }
            // Unchanged text is only re-dated (still the Mac's screen now), so
            // an unchanged card is not redrawn every second (r13 review).
            if model.cardScreenText != text { model.cardScreenText = text } else if live { model.confirmCardScreenText() }
        }
    }

    func overviewWillAppear(active tab: WorkspaceTab) {
        hosts[tab.id]?.prepareCard()
    }

    func overviewWillAppear(inactive tabs: [WorkspaceTab]) {
        // A tab whose card was never built has no host yet: its card asks
        // when the grid builds it.
        for tab in tabs { if let model = hosts[tab.id]?.model { refreshScreenText(for: tab, model: model, gridOpening: true) } }
    }

    // MARK: Cards while the grid shows (full verify D6, T-TABS-01)

    private var liveRefresh = TerminalCardLiveRefresh()
    private var liveRefreshTask: Task<Void, Never>?

    func overviewVisibilityChanged(_ visible: Bool, tabs: @escaping @MainActor () -> [WorkspaceTab]) {
        liveRefresh.setVisible(visible, now: CACurrentMediaTime())
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        guard visible else { return }
        // A UI refresh cadence, not synchronization: each tick asks only for
        // the cards that are due (`TerminalCardLiveRefresh`).
        liveRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await ContinuousClock().sleep(for: TerminalCardLiveRefresh.tick)
                guard !Task.isCancelled, let self else { return }
                self.refreshLiveCards(tabs())
            }
        }
    }

    func overviewScrollingChanged(_ scrolling: Bool) {
        liveRefresh.setScrolling(scrolling)
    }

    private func refreshLiveCards(_ tabs: [WorkspaceTab]) {
        // Only tabs whose card was built (a host exists): the grid builds the rest.
        let known = tabs.filter { hosts[$0.id] != nil }
        let states = known.compactMap { tab -> TerminalCardLiveRefresh.Tab? in
            guard let model = hosts[tab.id]?.model, !tab.hasEndedShell else { return nil }
            return TerminalCardLiveRefresh.Tab(id: tab.id, pageStarted: model.pageStarted,
                                               capturable: model.pageStarted && model.canCaptureCard, behind: model.cardIsBehind)
        }
        for action in liveRefresh.due(states, now: CACurrentMediaTime()) {
            switch action {
            case .snapshot(let id):
                hosts[id]?.model.refreshCardSnapshot()
            case .screenText(let id):
                guard let tab = known.first(where: { $0.id == id }), let model = hosts[id]?.model else { continue }
                // A live tab not attached yet shows its connecting card.
                if model.pageStarted, !model.connectionState.isAttached { continue }
                refreshScreenText(for: tab, model: model, live: true)
            }
        }
    }

    /// The settled grid shows the active page's snapshot, placed with its
    /// bottom at the card's bottom edge like every other terminal card, so
    /// the newest rows and the prompt show (V5-6). The snapshot draws the
    /// frame Ghostty presented (`TerminalSurfaceView.presentedImage`); the
    /// render server's copy was black over the rows (round 6).
    /// `-CmuxMobileLiveActiveCard` keeps the live page (the kit's top crop) for A/B.
    func showsStaticCard(for tab: WorkspaceTab) -> Bool {
        guard !CommandLine.arguments.contains("-CmuxMobileLiveActiveCard"),
              let model = hosts[tab.id]?.model, model.pageStarted else { return false }
        return model.snapshot != nil
    }

    func actions(for tab: WorkspaceTab, in workspace: Workspace) -> [TerminalTabAction] {
        let model = host(for: tab, in: workspace).model
        // The keyboard toggle and ^C live on the key bar, and Back leaves
        // the workspace, so the menu does not repeat them (design/terminal P1).
        var actions: [TerminalTabAction] = []
        // A Mac terminal: who shows it, the size each asks for, and the Mac's sizing policy.
        if let live = model.session as? DaemonTerminalSession, let macID = hostMacs[tab.id], let show = showConnectedDevices {
            actions.append(TerminalTabAction(title: "Connected Devices…", systemImage: "laptopcomputer.and.iphone") { show(live, macID) })
        }
        return actions + [
            TerminalTabAction(title: "Files and Links", systemImage: "folder") { model.showFilesAndLinks() },
            TerminalTabAction(title: "Paste", systemImage: "doc.on.clipboard") { model.paste() },
            TerminalTabAction(title: "Find…", systemImage: "magnifyingglass") { model.showFind() },
            // The Mac's Clear Screen and Scrollback: the Mac clears the terminal, scrollback
            // included, on the Mac and every phone (`clear-history`), not a Ctrl-L to the shell.
            TerminalTabAction(title: "Clear", systemImage: "clear", isEnabled: model.canClearScreenAndScrollback) {
                model.clearScreenAndScrollback()
            },
            TerminalTabAction(title: "Scroll to Bottom", systemImage: "arrow.down.to.line", isEnabled: model.isScrolledUp) { model.scrollToBottom() },
        ]
    }

    #if DEBUG
    /// DEBUG demos drive the open terminal tab through its model.
    func model(forTabID id: String) -> TerminalModel? { hosts[id]?.model }
    #endif
}

/// A short background task for the background release: begun before the
/// sessions release their sizes, ended after `endAfter`'s bound or when iOS
/// runs out of time, whichever is first (the size lease covers a lost release).
@MainActor
private final class SizeReleaseBackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "terminal-size-release") { [weak self] in
            // iOS calls this on the main thread; hop explicitly all the same.
            Task { @MainActor in self?.end() }
        }
    }

    func endAfter(_ bound: Duration) {
        guard id != .invalid else { return }
        // An intentional bounded delay (the release's time to reach the Mac).
        Task { @MainActor in
            try? await Task.sleep(for: bound)
            self.end()
        }
    }

    private func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// The host a tab's page shows now. Observed: when a placeholder host is
/// replaced by the live one, the page on screen swaps to it (R1-0).
@MainActor
@Observable
final class TerminalTabSlot {
    var host: TerminalTabHost

    init(host: TerminalTabHost) {
        self.host = host
    }
}

struct TerminalTabSlotPage: View {
    let slot: TerminalTabSlot
    let insets: EdgeInsets
    let isInteractive: Bool

    var body: some View {
        TerminalTabPage(host: slot.host, insets: insets, isInteractive: isInteractive)
            .id(ObjectIdentifier(slot.host))
    }
}

struct TerminalTabSlotCard: View {
    let slot: TerminalTabSlot
    let insets: EdgeInsets

    var body: some View {
        TerminalTabCard(model: slot.host.model, insets: insets)
            .id(ObjectIdentifier(slot.host))
    }
}
#endif
