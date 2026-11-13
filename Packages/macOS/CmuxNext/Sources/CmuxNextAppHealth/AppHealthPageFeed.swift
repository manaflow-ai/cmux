import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextPages
import CmuxNextWakeups

/// App health's page and renderer feed (the shared health contract, kinds `page` and `renderer`):
/// the page views' reports (``PageHealthFeed``) become the health model's signals, and its
/// `reloadPage` / `restartRenderer` go back to the page view.
///
/// - A page is timed only after its first heartbeat (a document still booting at a cold launch is
///   not silent) and only while the person can see it (``PageWebView/isShownForHealth``): a hidden
///   page sends no beats and costs nothing, however many pages are open. Occlusion changes (another
///   window or app on top, the Dock, a locked screen) come from the app's one occlusion observer
///   (`FrameScheduler.followSight`), for the windows that hold a timed page.
/// - Input: the first real key or click since the page's last beat marks input sent and not handled;
///   the next beat (at most 2 s later in a live page) marks it handled. Counting native events
///   against the page's own count drifts (a scrollbar click the page never sees), so the host counts
///   only "since the last beat"; a page that takes input and stops beating reads slow after 3 s.
@MainActor
final class AppHealthPageFeed: PageHealthFeed {
    private let health: AppHealth
    /// Pages that beat at least once, and the visibility each was last reported with.
    private var shown: [ObjectIdentifier: Bool] = [:]
    /// Each timed page's handled count at its last beat.
    private var lastHandled: [ObjectIdentifier: UInt64] = [:]
    /// Timed pages with a key or click since their last beat.
    private var inputSinceBeat: Set<ObjectIdentifier> = []
    /// Pages whose Chromium renderer has a part (it once stopped answering).
    private var renderers: Set<ObjectIdentifier> = []
    /// Crashed pages whose host shows the crash notice (``PageWebView/reloadsAfterCrash`` off): the
    /// notice's Reload is the person's, so health does not time them until a document loads again.
    private var showingCrashNotice: Set<ObjectIdentifier> = []

    init(health: AppHealth) {
        self.health = health
        health.setRepair(.page) { action in await Self.repair(action) }
        health.setRepair(.renderer) { action in await Self.repair(action) }
        let hang: AppHealth.Injector = { id, fault in await Self.inject(id, fault: fault) }
        health.setInjector(.page, hang)
        health.setInjector(.renderer, hang)
    }

    func pageBeat(_ page: PageWebView, handled: UInt64) {
        let key = ObjectIdentifier(page), id = page.healthPartID
        if shown[key] == nil {
            let visible = timedVisible(page)
            shown[key] = visible
            followSight(of: page)
            health.register(id, kind: .page, label: AppHealthStrings.pageLabel(resource: page.descriptor.resource, fallback: page.healthLabel), visible: visible)
        } else {
            pageVisibilityChanged(page)
        }
        lastHandled[key] = handled
        health.beat(id)
        // A beat answers the input sent since the last one: the page's thread ran after it. Its count cannot
        // decide (#39247 at aebd2ef): the host notes key ups, mouse ups, drags, scrollbar clicks and menu
        // choices the page never counts, so a healthy page would read as ignoring them and be reloaded.
        if inputSinceBeat.remove(key) != nil { health.input(id, sent: handled, handled: handled) }
    }

    func pageInput(_ page: PageWebView) {
        let key = ObjectIdentifier(page)
        guard shown[key] != nil, inputSinceBeat.insert(key).inserted else { return }
        let handled = lastHandled[key] ?? 0
        health.input(page.healthPartID, sent: handled + 1, handled: handled)
    }

    func pageVisibilityChanged(_ page: PageWebView) {
        let key = ObjectIdentifier(page)
        guard let was = shown[key] else { return }
        followSight(of: page)
        let visible = timedVisible(page)
        guard visible != was else { return }
        shown[key] = visible
        health.visibility(page.healthPartID, visible: visible)
        if renderers.contains(key) { health.visibility(Self.rendererID(page), visible: visible) }
    }

    func pageLoaded(_ page: PageWebView) {
        health.event(AppHealth.pageHostID, .loaded)
        let key = ObjectIdentifier(page)
        guard shown[key] != nil else { return }
        // A new document counts its handled input from 0 (pageHealth.ts), so the next beat compares with that.
        lastHandled[key] = 0
        health.event(page.healthPartID, .loaded)
        if showingCrashNotice.remove(key) != nil { pageVisibilityChanged(page) }
    }

    func pageLoadFailed(_ page: PageWebView) {
        health.event(AppHealth.pageHostID, .loadFailed)
    }

    func pageCrashed(_ page: PageWebView) {
        let key = ObjectIdentifier(page)
        guard shown[key] != nil else { return }
        guard page.reloadsAfterCrash else {
            showingCrashNotice.insert(key)
            pageVisibilityChanged(page)
            return
        }
        health.event(page.healthPartID, .crashed)
    }

    func pageRenderer(_ page: PageWebView, unresponsive: Bool) {
        let key = ObjectIdentifier(page), id = Self.rendererID(page)
        if unresponsive, renderers.insert(key).inserted {
            health.register(id, kind: .renderer, label: AppHealthStrings.pageLabel(resource: page.descriptor.resource, fallback: page.healthLabel), visible: page.isShownForHealth)
        }
        guard renderers.contains(key) else { return }
        health.event(id, unresponsive ? .unresponsive : .responsive)
    }

    func pageClosed(_ page: PageWebView) {
        let key = ObjectIdentifier(page)
        if shown.removeValue(forKey: key) != nil { health.unregister(page.healthPartID) }
        if renderers.remove(key) != nil { health.unregister(Self.rendererID(page)) }
        lastHandled[key] = nil
        inputSinceBeat.remove(key)
        showingCrashNotice.remove(key)
    }

    /// Whether health times the page now: the person can see it and no crash notice stands in for it.
    private func timedVisible(_ page: PageWebView) -> Bool {
        page.isShownForHealth && !showingCrashNotice.contains(ObjectIdentifier(page))
    }

    /// Follows the occlusion of the page's window (one follower per window; a page that moved to
    /// another window brings its new one).
    private func followSight(of page: PageWebView) {
        guard let window = page.window else { return }
        FrameScheduler.followSight(of: window, owner: self) { [weak self] in self?.refreshVisibility() }
    }

    /// A window's occlusion changed: each timed page reports its visibility again (only changes reach the model).
    private func refreshVisibility() {
        for page in PageRegistry.pages() where shown[ObjectIdentifier(page)] != nil { pageVisibilityChanged(page) }
    }

    static func rendererID(_ page: PageWebView) -> String { "renderer:\(PageRegistry.instance(of: page))" }

    /// The page a part id names (`page:<instance>`, `renderer:<instance>`).
    static func page(forPart id: String) -> PageWebView? {
        guard let instance = id.split(separator: ":").last.flatMap({ UInt64($0) }) else { return nil }
        return PageRegistry.pages().first { PageRegistry.instance(of: $0) == instance }
    }

    static func repair(_ action: AppHealth.Action) async -> Bool {
        guard let page = page(forPart: action.id) else { return false }
        // Unsaved edits a reload would drop: refuse, and the status says the repair did not run.
        guard !page.holdsEdits else { return false }
        switch action.action {
        case .reloadPage:
            return await page.reloadKeepingState()
        case .restartRenderer:
            // A renderer can be shared (Chromium keeps one per site): ending it reloads every page in it.
            guard !PageRegistry.pages().contains(where: \.holdsEdits) else { return false }
            page.restartRenderer()
            return true
        default:
            return false
        }
    }

    static func inject(_ id: String, fault: String) async -> Bool {
        guard fault == "hang", let page = page(forPart: id) else { return false }
        return await page.injectHealthHang()
    }
}
