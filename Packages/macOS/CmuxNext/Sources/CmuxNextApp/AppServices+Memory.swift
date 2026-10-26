// The app's memory consumer registrations (plans/cmux-next/chrome-parity/p07-memory.md, task 077).
//
// Chrome registers each memory consumer where it is built (base/memory_coordinator/memory_consumer.h:
// the consumer owns its RAII `MemoryConsumerRegistration`). cmux's composition root is AppServices, so
// the wiring of every package's consumers lives in this one file and AppServices.swift calls
// `registerMemoryConsumers()` once. Each package adds one line or one small function here, kept in
// package name order, so parallel changes add lines and do not edit the same ones. It is its own type,
// not an AppServices extension, so these lines never grow the AppServices god type.

import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextFavicons
import CmuxNextFeatures
import CmuxNextHibernation
import CmuxNextHome
import CmuxNextMemory
import CmuxNextPages
import CmuxNextResources
import CmuxNextSidebar
import CmuxNextTerminal
import CmuxNextWakeups

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
    /// work on `mainWork`. AppServices holds it next to its pressure source.
    ///
    /// - Parameters:
    ///   - pressure: The app's one memory pressure source.
    ///   - mainWork: The app's main-thread scheduler.
    /// - Returns: The coordinator.
    static func coordinator(pressure: MemoryPressureEvents, mainWork: MainWorkScheduler) -> MemoryCoordinator {
        MemoryCoordinator(pressure: pressure, slicer: FrameReleaseSlicer(
            queue: FrameBatchQueue(owner: "MemoryCoordinator.release", budgeted: .background, on: mainWork)))
    }

    /// AppServices' init calls this once, after the services the consumers belong to are built. Each
    /// consumer's owner keeps its registration token; nothing here stores one.
    func registerMemoryConsumers() {
        _ = services.memoryCoordinator  // follows pressure from launch, before any consumer registers
        // One line per package, sorted by package name, for example:
        // registerTabs()  // CmuxNextTabs
        registerAgentPaneCaches()  // CmuxNextAgentPane
        registerAppCaches()  // CmuxNextAgentPane, CmuxNextApp (p07-memory-056)
        registerImageCaches()  // CmuxNextApp, CmuxNextBridge
        registerInternalPageDiscards()  // CmuxNextApp
        registerBrowserCaches()  // CmuxNextBrowser
        // registerControlCaches(_:)  // CmuxNextControl: AppControl.start calls it when it makes the service
        registerDaemonCaches()  // CmuxNextDaemon
        registerConversationDiscards()  // CmuxNextHibernation, CmuxNextHome
        registerPageLifecycle()  // CmuxNextPages
        // registerSidebarDoc(_:)  // CmuxNextSidebar: SidebarDocWiring.start calls it when it makes the store
        registerTerminalLastFrames()  // CmuxNextTerminal
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
    /// is off. Caches made per page (Browse more art in Settings) take it at their init.
    var appCacheRegistry: (any MemoryConsumerRegistry)? {
        services.features.isEnabled(.memoryAppCaches) ? services.memoryCoordinator : nil
    }

    /// `memoryAppCaches` (default off): the app-lifetime caches (agent panes' saved frames and launch
    /// pages, decoded icon assets) are memory consumers (p07-memory-056).
    private func registerAppCaches() {
        guard let registry = appCacheRegistry else { return }
        services.launchImages.registerMemoryConsumer(with: registry)
        IconAssetImages.shared.registerMemoryConsumer(with: registry)
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

    /// `memoryTerminalLastFrames` (default off): evicted terminals' last frames are one lossless
    /// consumer that drops them all at critical and reports their volatile bytes apart (p07-memory-035).
    private func registerTerminalLastFrames() {
        guard services.features.isEnabled(.memoryTerminalLastFrames) else { return }
        services.cache.lastFrames.registerMemoryConsumer(with: services.memoryCoordinator)
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
    /// (p13-webui-022), on the app's one deadline scheduler. Agent chats join in p13-webui-038.
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
            guard let chromium = page.chromiumPage else { return WebContentProcess.identifier(of: page.webKitView).map { .webKit(pid: $0) } }
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
}
