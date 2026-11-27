import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextPages
import CmuxNextWakeups
import os

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
/// - Rest: a page with nothing happening in it for 10 s sends a `rest` beat and stops beating, so an
///   idle app wakes for no page (CMUX-571). Its silence is not timed then; input sent to it is, from
///   the first key or click, and the page beats again once it handled it.
/// - Liveness (the rest's blind spot): a page whose main thread never runs again (a synchronous loop)
///   sends no beat and reads as resting, and Chromium reports a hang only for unanswered input. So
///   each renderer of visible agent chats is one `liveness` part (``livenessID(of:)``): every beat of
///   its pages answers it, and once they all rest the model asks for a `ping` (one `Runtime.evaluate`
///   of `0`, which needs that main thread) every 15 s. Two unanswered over 30 s, visible and awake,
///   end that renderer (``endRenderer(_:pages:)``); every page in it reloads and says so. Hidden
///   renderers have no deadline, and a sleep since the first ping or a debugger voids the pings out.
@MainActor
final class AppHealthPageFeed: PageHealthFeed {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.health")
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
    /// Each liveness part (one per renderer of agent chats) and the pages in it.
    private var livenessPages: [String: Set<ObjectIdentifier>] = [:]
    /// The liveness part each timed agent page is in.
    private var livenessOf: [ObjectIdentifier: String] = [:]
    /// The visibility each liveness part was last reported with.
    private var livenessShown: [String: Bool] = [:]
    /// Each liveness part's first unanswered ping: the renderer's usage then (the log's CPU share
    /// over the hang) and the Mac's slept time then (a sleep since voids the pings).
    private var firstPing: [String: FirstPing] = [:]
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.health")
    /// How long one ping waits for its answer: past the model's second ping, so a slow answer still
    /// counts, and bounded, so a hung renderer's call ends.
    static let pingTimeout: Duration = .seconds(30)

    init(health: AppHealth) {
        self.health = health
        health.setRepair(.page) { action in await Self.repair(action) }
        health.setRepair(.renderer) { action in await Self.repair(action) }
        health.setRepair(.liveness) { [weak self] action in await self?.liveness(action) ?? false }
        let hang: AppHealth.Injector = { id, fault in await Self.inject(id, fault: fault) }
        health.setInjector(.page, hang)
        health.setInjector(.renderer, hang)
    }

    func pageBeat(_ page: PageWebView, handled: UInt64, resting: Bool) {
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
        health.beat(id, rest: resting)
        // Any beat, a rest beat too, says its renderer's main thread ran.
        if let part = joinLiveness(page) {
            firstPing[part] = nil
            health.beat(part)
        }
        // A beat answers the input sent since the last one: the page's thread ran after it. Its count cannot
        // decide (#39247 at aebd2ef): the host notes key ups, mouse ups, drags, scrollbar clicks and menu
        // choices the page never counts, so a healthy page would read as ignoring them and be reloaded.
        if inputSinceBeat.remove(key) != nil { health.input(id, sent: handled, handled: handled) }
    }

    var takesRestBeats: Bool { health.takesRestBeats }

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
        if let part = livenessOf[key] { refreshLiveness(part) }
        guard visible != was else { return }
        shown[key] = visible
        health.visibility(page.healthPartID, visible: visible)
        if renderers.contains(key) { health.visibility(Self.rendererID(page), visible: visible) }
    }

    func pageNavigationStarted(_ page: PageWebView) {
        let key = ObjectIdentifier(page)
        guard shown[key] != nil else { return }
        // The old document's input died with it, and the new one counts its handled input from 0.
        lastHandled[key] = 0
        inputSinceBeat.remove(key)
        health.event(page.healthPartID, .navigationStarted)
    }

    func pageLoaded(_ page: PageWebView) {
        health.event(AppHealth.pageHostID, .loaded)
        let key = ObjectIdentifier(page)
        guard shown[key] != nil else { return }
        // A new document counts its handled input from 0 (pageHealth.ts), so the next beat compares with that.
        lastHandled[key] = 0
        health.event(page.healthPartID, .loaded)
        if showingCrashNotice.remove(key) != nil { pageVisibilityChanged(page) }
        // A new document may live in a new renderer (the one the watchdog ended is gone).
        if let part = joinLiveness(page) { health.beat(part) }
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
        leaveLiveness(key)
    }

    // MARK: Liveness

    /// The liveness part `page` belongs to: its renderer's, or its own when the renderer is not
    /// known; nil for a page the watchdog does not time (not an agent chat in Chromium) or a model
    /// without liveness parts.
    func livenessID(of page: PageWebView) -> String? {
        guard health.timesLiveness, page.isTimedForLiveness else { return nil }
        if let client = page.rendererClientID { return "liveness:\(client)" }
        return "liveness:page-\(PageRegistry.instance(of: page))"
    }

    /// Puts a timed page in its renderer's part (moving it from an older one) and returns that part.
    @discardableResult
    private func joinLiveness(_ page: PageWebView) -> String? {
        let key = ObjectIdentifier(page)
        guard shown[key] != nil, let part = livenessID(of: page) else {
            leaveLiveness(key)
            return nil
        }
        if livenessOf[key] == part { return part }
        leaveLiveness(key)
        livenessOf[key] = part
        if livenessPages[part, default: []].insert(key).inserted, livenessPages[part]?.count == 1 {
            let visible = timedVisible(page)
            livenessShown[part] = visible
            health.register(part, kind: .liveness, label: AppHealthStrings.agentChatsLabel, visible: visible)
        }
        refreshLiveness(part)
        return part
    }

    private func leaveLiveness(_ key: ObjectIdentifier) {
        guard let part = livenessOf.removeValue(forKey: key) else { return }
        livenessPages[part]?.remove(key)
        guard livenessPages[part]?.isEmpty != false else { return refreshLiveness(part) }
        livenessPages[part] = nil
        livenessShown[part] = nil
        firstPing[part] = nil
        health.unregister(part)
    }

    /// The pages in liveness part `part` (alive ones).
    private func pages(in part: String) -> [PageWebView] {
        guard let members = livenessPages[part] else { return [] }
        return PageRegistry.pages().filter { members.contains(ObjectIdentifier($0)) }
    }

    /// A liveness part is visible while any of its pages is: a renderer nobody sees is not timed.
    private func refreshLiveness(_ part: String) {
        let visible = pages(in: part).contains { timedVisible($0) }
        guard livenessShown[part] != visible else { return }
        livenessShown[part] = visible
        firstPing[part] = nil
        health.visibility(part, visible: visible)
    }

    /// Nanoseconds the Mac has slept since boot: the continuous clock counts sleep, uptime does
    /// not. A ping sent before a sleep says nothing about the renderer after the wake, so a growth
    /// since the first ping voids the pings, with no sleep observer to keep.
    static func sleptNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) &- clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// The pings out for `part` are void (a sleep, a debugger): the model starts its count again.
    private func voidPings(_ part: String) -> Bool {
        firstPing[part] = nil
        health.event(part, .void)
        return true
    }

    /// Whether the Mac slept since `part`'s first unanswered ping (more than a second).
    private func sleptSinceFirstPing(_ part: String) -> Bool {
        guard let first = firstPing[part] else { return false }
        return Self.sleptNanos() &- first.slept > 1_000_000_000
    }

    /// The model's `ping` and `endRenderer` for one renderer of agent chats.
    private func liveness(_ action: AppHealth.Action) async -> Bool {
        let members = pages(in: action.id)
        let pid = members.first?.rendererProcessID
        // A debugger stops a main thread on purpose (DevTools on one of its pages, a debugger on the
        // app or on the renderer): that time never counts.
        if members.contains(where: \.isBeingDebugged) || ProcessUsage.isTraced(getpid()) || pid.map(ProcessUsage.isTraced) == true
            || sleptSinceFirstPing(action.id) {
            return voidPings(action.id)
        }
        switch action.action {
        case .ping:
            guard let page = members.first(where: { timedVisible($0) }) else { return false }
            if firstPing[action.id] == nil {
                firstPing[action.id] = FirstPing(usage: pid.flatMap(ProcessUsage.sample), slept: Self.sleptNanos())
            }
            guard await page.pingMainThread(timeout: Self.pingTimeout), livenessOf[ObjectIdentifier(page)] == action.id else { return true }
            firstPing[action.id] = nil
            health.beat(action.id)
            return true
        case .endRenderer:
            return endRenderer(action, pages: members)
        default:
            return false
        }
    }

    /// Ends a renderer the model proved hung: one log line first (which pages, how long, the
    /// renderer's memory and CPU, the page's last message), then every page in it is marked to
    /// reload as a repair with its one-line notice, then the renderer ends.
    private func endRenderer(_ action: AppHealth.Action, pages members: [PageWebView]) -> Bool {
        guard let target = members.first(where: { timedVisible($0) }) ?? members.first else { return false }
        let pid = target.rendererProcessID
        let usage = pid.flatMap(ProcessUsage.sample)
        let hung = Double(action.hungMs ?? 0) / 1000
        let cpu = usage.flatMap { now in firstPing[action.id]?.usage.map { String(format: "%.0f%%", now.cpuShare(since: $0) * 100) } } ?? "unknown"
        let footprint = usage.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0.physFootprint), countStyle: .memory) } ?? "unknown"
        let cpuTotal = usage.map { String(format: "%.0f s", Double($0.cpuNanos) / 1e9) } ?? "unknown"
        let now = ProcessInfo.processInfo.systemUptime
        let named = members.prefix(8).map { $0.livenessLogEntry(visible: timedVisible($0), now: now) }.joined(separator: " ")
        let more = members.count > 8 ? " +\(members.count - 8) more" : ""
        logger.error("""
            agent chat renderer hung: ending it renderer=\(action.id, privacy: .public) pid=\(pid ?? 0) \
            hung=\(String(format: "%.0f", hung), privacy: .public)s footprint=\(footprint, privacy: .public) \
            cpu=\(cpu, privacy: .public) cpuTotal=\(cpuTotal, privacy: .public) pages=\(members.count) \
            \(named, privacy: .public)\(more, privacy: .public)
            """)
        guard PageWebView.endHungRenderer(of: [target] + members.filter { $0 !== target }, notice: AppHealthStrings.chatRestarted) != nil else {
            logger.error("agent chat renderer \(action.id, privacy: .public) could not be ended (no single renderer process)")
            return false
        }
        firstPing[action.id] = nil
        return true
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
        // Which chat: the page and the daemon tab it shows.
        logger.notice("health: \(action.action.rawValue, privacy: .public) \(action.id, privacy: .public) is page \(page.descriptor.id, privacy: .public) tab \(page.healthTabKey() ?? "none", privacy: .public)")
        // Unsaved edits a reload would drop: refuse, and the status says the repair did not run.
        guard !page.holdsEdits else { return false }
        switch action.action {
        case .reloadPage:
            return await page.reloadKeepingState()
        case .restartRenderer:
            // A renderer can be shared (Chromium keeps one per site): ending it reloads every page in
            // it, so edits in any of them refuse it. Pages in other renderers lose nothing.
            let renderer = page.rendererClientID
            guard !PageRegistry.pages().contains(where: { $0.holdsEdits && (renderer == nil || $0.rendererClientID == renderer) }) else { return false }
            return page.restartRenderer()
        default:
            return false
        }
    }

    static func inject(_ id: String, fault: String) async -> Bool {
        guard fault == "hang", let page = page(forPart: id) else { return false }
        return await page.injectHealthHang()
    }
}

/// A liveness part's first unanswered ping (``AppHealthPageFeed``).
private struct FirstPing {
    var usage: ProcessUsage?
    var slept: UInt64
}
