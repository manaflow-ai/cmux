// The app's memory consumer registrations (plans/cmux-next/chrome-parity/p07-memory.md, task 077).
//
// Chrome registers each memory consumer where it is built (base/memory_coordinator/memory_consumer.h:
// the consumer owns its RAII `MemoryConsumerRegistration`). cmux's composition root is AppServices, so
// the wiring of every package's consumers lives in this one file and AppServices.swift calls
// `registerMemoryConsumers()` once. Each package adds one line or one small function here, kept in
// package name order, so parallel changes add lines and do not edit the same ones. It is its own type,
// not an AppServices extension, so these lines never grow the AppServices god type.

import CmuxNextAgentPane
import CmuxNextApps
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextFavicons
import CmuxNextFeatures
import CmuxNextFileGrid
import CmuxNextHibernation
import CmuxNextHistory
import CmuxNextHome
import CmuxNextMemory
import CmuxNextPages
import CmuxNextResources
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextTerminal
import CmuxNextWakeups
import Foundation

/// Runs the memory coordinator's release slices on a budgeted frame queue: on a later frame, after input
/// and visible work, never in the turn that asks (Chrome posts memory release as BEST_EFFORT tasks).
private final class FrameReleaseSlicer: MemoryReleaseSlicer {
    /// The background-class queue the slices run on.
    let queue: FrameBatchQueue

    init(queue: FrameBatchQueue) {
        self.queue = queue
    }

    func scheduleSlice(_ slice: @escaping @MainActor () -> Void) {
        queue.enqueue(slice)
    }
}

/// Registers every package's memory consumers with the app's memory coordinator.
struct AppMemoryConsumers {
    /// The services whose subsystems own the consumers.
    let services: AppServices

    /// The app's one memory coordinator: it follows `pressure` and releases in background-class frame
    /// work on the main-thread scheduler of `deadlines`, or on main run loop passes while the app is hidden
    /// (``followHiddenApp()``). Two background-class one-shots on `deadlines` hold lossless limits 30 s after a
    /// fall in level and release working-set entries a release kept once they age out (p07-memory-070).
    /// AppServices holds it next to its pressure source.
    ///
    /// - Parameters:
    ///   - pressure: The app's one memory pressure source.
    ///   - deadlines: The app's one `MainDeadline` placer, on the app's main-thread scheduler.
    /// - Returns: The coordinator.
    static func coordinator(pressure: MemoryPressureEvents, deadlines: MainDeadlineScheduler) -> MemoryCoordinator {
        MemoryCoordinator(
            pressure: pressure,
            slicer: FrameReleaseSlicer(
                queue: FrameBatchQueue(owner: "MemoryCoordinator.release", budgeted: .background, on: deadlines.work)),
            turns: MainRunLoopReleaseTurns(),
            limitRiseDeadline: MainDeadline(
                owner: "MemoryCoordinator.limitRise", workClass: .background, scheduler: deadlines),
            workingSetDeadline: MainDeadline(
                owner: "MemoryCoordinator.workingSet", workClass: .background, scheduler: deadlines))
    }

    /// AppServices' init calls this once, after the services the consumers belong to are built. Each
    /// consumer's owner keeps its registration token; nothing here stores one.
    func registerMemoryConsumers() {
        _ = services.memoryCoordinator  // follows pressure from launch, before any consumer registers
        followHiddenApp()  // CmuxNextMemory (p07-memory-071)
        // One line per package, sorted by package name, for example:
        // registerTabs()  // CmuxNextTabs
        registerAgentPaneCaches()  // CmuxNextAgentPane
        registerAppCaches()  // CmuxNextAgentPane, CmuxNextApp (p07-memory-056)
        registerImageCaches()  // CmuxNextApp, CmuxNextBridge
        registerInternalPageDiscards()  // CmuxNextApp
        registerBrowserCaches()  // CmuxNextBrowser
        // registerControlCaches(_:)  // CmuxNextControl: AppControl.start calls it when it makes the service
        registerDaemonCaches()  // CmuxNextDaemon
        followDaemonMemoryLimit()  // CmuxNextDaemon (p07-memory-109)
        registerDesignCaches()  // CmuxNextDesign (p07-memory-053)
        registerSmallAppStores()  // CmuxNextDesign, CmuxNextTerminal (p07-memory-083)
        registerGlyphMasks()  // CmuxNextDesign (p03-rendering-075)
        registerConversationDiscards()  // CmuxNextHibernation, CmuxNextHome
        registerHiddenFrames()  // CmuxNextHibernation, CmuxNextTerminal
        registerPageLifecycle()  // CmuxNextPages
        // registerSidebarDoc(_:)  // CmuxNextSidebar: SidebarDocWiring.start calls it when it makes the store
        registerTabCaches()  // CmuxNextTabs
        registerTerminalLastFrames()  // CmuxNextTerminal
    }

    /// `memoryHiddenAppRelease` (default off): while no window shows, the coordinator releases in 8 ms slices on
    /// main run loop passes; the person's input puts it back on 2 ms frame slices (p07-memory-071).
    func followHiddenApp() {
        guard services.features.isEnabled(.memoryHiddenAppRelease) else { return }
        services.memoryCoordinator.followApp(windows: services.appVisibility.shownWindows, input: services.inputTap)
    }

    /// `memoryAgentAndControlCaches` (default off): the agent pane's New Tab frames, chat tails and
    /// project icons (p07-memory-060).
    func registerAgentPaneCaches() {
        guard services.features.isEnabled(.memoryAgentAndControlCaches) else { return }
        AgentPaneMemoryConsumers(registry: services.memoryCoordinator).register()
    }

    /// `memoryAgentAndControlCaches` (default off): the control service's idempotency cache
    /// (p07-memory-060). The service is made after ``registerMemoryConsumers()``, so `AppControl.start`
    /// calls this with it; the service keeps the registration.
    func registerControlCaches(_ service: ControlService) {
        guard services.features.isEnabled(.memoryAgentAndControlCaches) else { return }
        service.registerMemoryConsumer(with: services.memoryCoordinator)
    }

    /// `memoryAgentAndControlCaches` (default off): the launch's login environment (p07-memory-060).
    func registerDaemonCaches() {
        guard services.features.isEnabled(.memoryAgentAndControlCaches) else { return }
        DaemonLauncher.registerLoginEnvironmentMemoryConsumer(with: services.memoryCoordinator)
    }

    /// `memoryDaemonLimit` (default off): the local daemon, and through it acpmux, hear the coordinator's level,
    /// Memory Saver mode and debug override on each change (`memory.limit`) and take the worse of their own level
    /// and the app's, as Chrome's browser hands each child process its limit (`ChildMemoryConsumerRegistryHost`,
    /// content/browser/memory_coordinator/README.md). A Cloud machine's daemon does not follow this Mac's memory.
    func followDaemonMemoryLimit() {
        guard services.features.isEnabled(.memoryDaemonLimit), services.daemon.isLocal else { return }
        let coordinator = services.memoryCoordinator, daemon = services.daemon
        let follow = DaemonMemoryLimitFollow(Self.memoryLimit(of: coordinator), store: daemon.store,
                                             on: services.mainWork) { [weak daemon] request in
            _ = await daemon?.run("memory.limit") { _ = try await $0.request(request) }
        }
        services.lifetimeFollowers.append(DaemonMemoryLimitLink(
            follow: follow, registry: coordinator, observeOverrides: { coordinator.observePressureOverride($0) }
        ) { [weak coordinator] in
            coordinator.map { Self.memoryLimit(of: $0) } ?? MemoryLimitRequest(level: .normal, mode: .medium)
        })
    }

    /// The limit `coordinator` acts on now: its level (the debug override folded in), mode and override.
    static func memoryLimit(of coordinator: MemoryCoordinator) -> MemoryLimitRequest {
        MemoryLimitRequest(level: coordinator.level, mode: coordinator.mode, pressureOverride: coordinator.pressureOverride)
    }

    /// `memoryBackdropImages` (default off): the windows' decoded backdrop pictures (`backdrops`, the store
    /// every window shares) are one lossless consumer (p07-memory-053).
    func registerDesignCaches(backdrops: BackdropImageStore = .shared) {
        guard services.features.isEnabled(.memoryBackdropImages) else { return }
        backdrops.registerMemoryConsumer(with: services.memoryCoordinator)
    }

    /// `sharedGlyphMasks` (default off): the chrome labels of `scope`'s tree (the app's) draw their glyphs
    /// through one byte-capped cache, so equal labels draw once; one lossless consumer (p03-rendering-075).
    func registerGlyphMasks(in scope: ThemeScope = .app) {
        guard services.features.isEnabled(.sharedGlyphMasks) else { return }
        let masks = GlyphMaskCache()
        masks.registerMemoryConsumer(with: services.memoryCoordinator)
        scope.sharedGlyphMasks = masks
    }

    /// `memoryHomeLabCaches` (default off): the Home transcript's shared pixel caches and the Home lists' row
    /// bitmaps as one lossless consumer on `homeRenderBitmapBytes`, emptied after 60 s with no Home view shown
    /// (p07-memory-081). Nil while the feature is off; Home makes it with its service and keeps it.
    func makeHomeLabCaches() -> MessagesLabMemoryConsumer? {
        guard services.features.isEnabled(.memoryHomeLabCaches) else { return nil }
        return MessagesLabMemoryConsumer(
            budgetBytes: SubsystemBudget.forThisMac(gpuResidentAvailable: false).homeRenderBitmapBytes,
            registry: services.memoryCoordinator,
            idle: MainDeadline(owner: "Home.labCaches.idle", workClass: .background, scheduler: services.mainDeadlines))
    }

    /// The sidebar document store's projection memo: one lossless entry, dropped at critical
    /// (p07-memory-054). The store is made lazily with the sidebar layout, so `SidebarDocWiring.start` calls this.
    func registerSidebarDoc(_ store: SidebarDocStore) {
        store.registerMemoryConsumer(with: services.memoryCoordinator)
    }

    /// `memoryBrowserCaches` (default off): the tab strips' favicon store and the favicon loader's
    /// per-profile caches hold the same icons, so they are one lossless consumer (p07-memory-055).
    private func registerBrowserCaches() {
        guard services.features.isEnabled(.memoryBrowserCaches) else { return }
        services.favicons.registerMemoryConsumer(with: services.memoryCoordinator, loaderCache: BrowserFaviconLoader.shared)
    }

    /// `memoryAppCaches` (default off): the registry the app's caches register with, nil while the feature
    /// is off. Caches made per page take it at their init: Browse more art in Settings (p07-memory-056),
    /// the Apps page's glyph masks and the Settings page's backdrop thumbnails (p07-memory-057).
    var appCacheRegistry: (any MemoryConsumerRegistry)? {
        services.features.isEnabled(.memoryAppCaches) ? services.memoryCoordinator : nil
    }

    /// `memoryAppCaches` (default off): the app-lifetime caches (agent panes' saved frames and launch
    /// pages, decoded icon assets, Launch Services' kept icons) are memory consumers (p07-memory-056,
    /// p02-threads-056).
    private func registerAppCaches() {
        guard let registry = appCacheRegistry else { return }
        services.launchImages.registerMemoryConsumer(with: registry)
        IconAssetImages.shared.registerMemoryConsumer(with: registry)
        services.workspaceQueries.registerMemoryConsumer(with: registry)
    }

    /// `memoryImageCaches` (default off): terminal previews are a rebuildable consumer that shrinks at warning;
    /// page thumbnails and discarded internal pages' pictures, the only copies, are limited only at critical
    /// (p07-memory-058). The hibernation pictures register when the hibernation starts
    /// (``registerHibernationSnapshots(_:)``).
    func registerImageCaches() {
        guard services.features.isEnabled(.memoryImageCaches) else { return }
        let cache = services.cache, coordinator = services.memoryCoordinator
        cache.previews.registerMemoryConsumer(name: Self.previewImagesName, with: coordinator)
        cache.pageThumbnails.registerMemoryConsumer(name: Self.pageThumbnailsName, with: coordinator)
        cache.internalPagePictures.registerMemoryConsumer(name: Self.internalPagePicturesName, with: coordinator)
    }

    /// The image caches' names in the memory report.
    static let previewImagesName = "preview-images"
    static let pageThumbnailsName = "page-thumbnails"
    static let internalPagePicturesName = "internal-page-pictures"

    /// `memoryImageCaches` (default off): `hibernation`'s pictures are a lossy consumer that keeps only the
    /// neighbors' pictures at critical (p07-memory-058). `startHibernation` calls it once it made the hibernation.
    func registerHibernationSnapshots(_ hibernation: BrowserHibernation) {
        guard services.features.isEnabled(.memoryImageCaches) else { return }
        hibernation.snapshots.registerMemoryConsumer(with: services.memoryCoordinator)
    }

    /// `memoryFileHomeCaches` (default off): the registry the Files, Screenshots and app bundle image
    /// caches register with, nil while the feature is off (p07-memory-059). Lazy services (the Files
    /// pane, the Screenshots pages) take it when they are made.
    var fileCacheRegistry: (any MemoryConsumerRegistry)? {
        services.features.isEnabled(.memoryFileHomeCaches) ? services.memoryCoordinator : nil
    }

    /// `webKitSameSiteProcesses` (default off): WebKit tabs share a same-site WebContent process from the Chromium
    /// renderer limit on (p07-memory-088), or from the limit a bench run forces; nil while the feature is off.
    var webKitProcessReuse: WebKitProcessReuse? {
        guard services.features.isEnabled(.webKitSameSiteProcesses) else { return nil }
        let limit = WebKitProcessReuse.benchRendererLimit(environment: ProcessInfo.processInfo.environment,
                                                          bundleIdentifier: Bundle.main.bundleIdentifier)
            ?? SubsystemBudget.forThisMac(gpuResidentAvailable: false).chromiumRendererLimit
        return WebKitProcessReuse.loading(rendererLimit: limit, work: services.work, mainWork: services.mainWork)
    }

    /// The Files pane's thumbnail pixel bytes, a quarter of the Mac's image cache budget (32 MiB at
    /// 16 GB), whatever the feature state: only the registration waits for `memoryFileHomeCaches`.
    var filesThumbnailBytes: Int {
        SubsystemBudget.forThisMac(gpuResidentAvailable: false).imageCacheBytes / 4
    }

    /// `memoryFileHomeCaches`: the grid thumbnail cache of the Screenshots pages as an asynchronous
    /// consumer (its state stays on its actor); its owner keeps the registration. Nil while the
    /// feature is off.
    func registerFileGridThumbnails(_ cache: ThumbnailCache) -> AsyncMemoryConsumerRegistration? {
        fileCacheRegistry.map {
            AsyncMemoryConsumerRegistration(name: ThumbnailCache.memoryConsumerName, traits: ThumbnailCache.memoryTraits,
                                            consumer: cache, registry: $0)
        }
    }

    /// `memorySqliteTrim` (default off): one browser profile's visit log, whose SQLite page cache is an
    /// asynchronous consumer on the log's actor (p07-memory-090); its owner, the history service, keeps the
    /// registration while it keeps the log. Nil while the feature is off.
    func registerVisitLog(_ log: BrowserVisitLog) -> AsyncMemoryConsumerRegistration? {
        guard services.features.isEnabled(.memorySqliteTrim) else { return nil }
        return AsyncMemoryConsumerRegistration(name: BrowserVisitLog.memoryConsumerName, traits: BrowserVisitLog.memoryTraits,
                                               consumer: log, registry: services.memoryCoordinator)
    }

    /// `memoryFileHomeCaches`: the apps client's decoded bundle images are one lossless consumer;
    /// their owner, the apps service, calls this when it makes them.
    func registerAppBundleImages(_ cache: AppBundleImageCache) {
        guard let registry = fileCacheRegistry else { return }
        cache.registerMemoryConsumer(with: registry)
    }

    /// `memoryTabCaches` (default off): the tab strips' drawn symbols, pack icons, agent marks, emoji and
    /// known symbol names are lossless consumers that keep only what was drawn in the last 2 s at critical
    /// (p07-memory-052). The hover card thumbnails register with each strip (PaneController).
    private func registerTabCaches() {
        guard services.features.isEnabled(.memoryTabCaches) else { return }
        TabIconMemoryConsumers(registry: services.memoryCoordinator).register()
    }

    /// `memoryTerminalLastFrames` (default off): evicted terminals' last frames are one lossless
    /// consumer that drops them all at critical and reports their volatile bytes apart (p07-memory-035).
    private func registerTerminalLastFrames() {
        guard services.features.isEnabled(.memoryTerminalLastFrames) else { return }
        services.cache.lastFrames.registerMemoryConsumer(with: services.memoryCoordinator)
    }

    /// `memoryHiddenFrameLRU` (default off): evicted terminals' last frames are frames of the app-wide hidden
    /// frame list, which decides which stay under the warm set's capacity; the list registers itself with the
    /// coordinator as it is built (p03-rendering-099).
    private func registerHiddenFrames() {
        guard let frames = services.hiddenFrames else { return }
        services.cache.lastFrames.keeper = frames
    }

    /// `memoryDiscardConversations` (default off): hidden conversation tabs' laid-out transcripts go after 10 min.
    private func registerConversationDiscards() {
        guard services.features.isEnabled(.memoryDiscardConversations) else { return }
        Self.conversationDiscards(ContentDiscardScheduler(kind: .conversation, memory: services.memoryCoordinator), on: services.cache) {
            [weak services] key in services?.home.existingTabView(key)?.transcript
        }
    }

    /// Conversation tabs' transcripts (`transcript`, by tab key) let their rows go on `cache`'s lifecycle, as
    /// `scheduler` says; the cache's content owners keep the host.
    static func conversationDiscards(_ scheduler: ContentDiscardScheduler, on cache: TabContentCache,
                                     transcript: @escaping (String) -> HomeNativeTranscriptView?) {
        let lifecycle = LayoutDiscardHost<ContentLifecycle<String>.Token>.Lifecycle(
            isHidden: { [weak cache] key in cache?.phase(of: key) == .mountedHidden },
            adopted: { [weak cache] key in cache?.ledger.setRetained(key, false) },
            hibernate: { [weak cache] key in cache?.applyLifecycle(cache?.lifecycle.send(.hibernate(key)) ?? []) },
            mounted: { [weak cache] key, token in cache?.applyLifecycle(cache?.lifecycle.send(.mounted(key, token)) ?? []) })
        cache.contentOwners.add(LayoutDiscardHost(scheduler: scheduler, layout: { key in
            transcript(key).map(HomeTranscriptLayout.init).map { rows in
                DiscardableLayout(isReleased: { rows.isReleased }, isAtRest: { rows.isAtRest }, release: { rows.release() }, restore: { rows.restore() })
            }
        }, lifecycle: lifecycle))
    }

    /// `pageLifecycle` (default off): page tabs' reveal and conceal drive the page lifecycle
    /// (p13-webui-022), on the app's one deadline scheduler. Agent chats and New Tab pages join it when
    /// the browser hibernation makes their `AgentPageHibernation` (p13-webui-038).
    private func registerPageLifecycle() {
        guard services.features.isEnabled(.pageLifecycle) else { return }
        installPageLifecycle(PageLifecycle(deadlines: services.mainDeadlines))
    }

    /// Makes `lifecycle` the one lifecycle of cmux pages: a page tab's reveal and conceal drive it, a
    /// page WebUIHost closes leaves it, and the browser hibernation (`startHibernation`) hands it
    /// `browser.hibernation`, the memory pressure and Low Power Mode. Tests pass one on their own deadlines.
    func installPageLifecycle(_ lifecycle: PageLifecycle) {
        let pages = services.pages
        let encoder = PageSnapshotEncoder(work: services.work, mainWork: services.mainWork)
        lifecycle.pageOfTab = { [weak pages] key in
            (pages?.existingView(key)?.content as? PageWebView).map { PageWebViewLifecycle($0, encoder: encoder) }
        }
        services.webUI.lifecycle = lifecycle
        // Crash budgets per renderer: Chromium groups pages only with `pageProcessGroups` (FirstPartyPageSchemes).
        services.webUI.crashGroups = PageCrashGroups(chromiumSharesByGroup: services.features.isEnabled(.pageProcessGroups)) { page in
            guard let chromium = page.chromiumPage else { return page.webKitEngine.flatMap { WebContentProcess.identifier(of: $0) }.map { .webKit(pid: $0) } }
            return (chromium as? CEFPageChromiumPage)?.soleRendererClientID.map { .chromium(client: $0) }
        }
        services.cache.pageLifecycle = lifecycle
    }

    /// `memoryDiscardInternalPages` (default off): hidden page tabs' views go after their policy. With
    /// `pageLifecycle` on, that lifecycle is page tabs' one discard controller, so this one stays off.
    private func registerInternalPageDiscards() {
        guard services.features.isEnabled(.memoryDiscardInternalPages), !services.features.isEnabled(.pageLifecycle) else { return }
        services.pages.enableDiscards(ContentDiscardScheduler(kind: .internalPage, memory: services.memoryCoordinator), on: services.cache)
    }

    /// `memorySmallAppStores` (default off): the glass lens stills are one lossless consumer, the last quit's
    /// terminal frames one lossy consumer, and the terminals' Kitty image budget halves below normal pressure
    /// (p07-memory-083). The changelog page's pictures register with each page (`PageFactory.changelogPage`), and the
    /// launch reads go at the settle (`LaunchSettle.dropLaunchReads`).
    private func registerSmallAppStores() {
        guard services.features.isEnabled(.memorySmallAppStores) else { return }
        let coordinator = services.memoryCoordinator
        GlassBackdropImages.shared.registerMemoryConsumer(with: coordinator)
        services.terminalLaunchFrames.registerMemoryConsumer(with: coordinator)
        let kittyImages = GhosttyImageStorageBudget(
            fullBytes: SubsystemBudget.forThisMac(gpuResidentAvailable: false).kittyImageBytesPerSurface,
            riseDeadline: MainDeadline(owner: "GhosttyImageStorageBudget.rise", workClass: .background, scheduler: services.mainDeadlines),
            riseDelay: MemoryCoordinator.limitRiseDelay) { GhosttyRuntime.shared.setImageStorageBytesPerScreen($0) }
        kittyImages.follow(coordinator)
        services.lifetimeFollowers.append(kittyImages)
    }
}
