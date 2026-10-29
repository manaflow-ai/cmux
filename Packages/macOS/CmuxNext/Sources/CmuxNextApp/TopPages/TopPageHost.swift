import AppKit
import CmuxHomeCore
import CmuxNextCompat
import CmuxNextFeatures
import CmuxNextHibernation
import CmuxNextHomeEngine
import CmuxNextMemory
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups

/// One window's top pages: one view per route, made on first show. A page the window stops showing
/// stays live, so it keeps its state (scroll, search, the composer draft) when the window switches
/// to a workspace and back, until its discard policy (`PageDiscardPolicy`) says it may go. Then its
/// view is released and a `PageViewState` stays; the next show builds the page again and restores
/// it. Behind the `topPageDiscard` feature (default off); off, every view stays for the window's
/// life as before. Page models stay shared through their providers.
///
/// Only a page with a `PageDiscardable` owner is discarded (classic Home today): the web-backed
/// pages (History, Bookmarks, Settings, app pages) record neither their web scroll, their route nor
/// what is typed in their web content, so they stay for the window's life until their providers
/// opt in.
///
/// Live hidden top pages are also held to the Mac's budget across all windows
/// (`SubsystemBudget.liveHiddenInternalPages`, ``releaseOverLimit(_:limit:)``), never a page hidden
/// less than ``budgetMinimumHidden``. Eligibility is the one planner's (`ContentDiscardPlanner`,
/// kind `topPage`), so input the record does not keep holds a page at any pressure (the lead rule's
/// form input). Events only: content swaps, a page leaving the window, and one deadline per window
/// for its next page to come due.
///
/// The memory coordinator hands each window's host the Memory Saver mode, which scales a page's
/// timeout (off: no timed release), and the pressure level: at critical a hidden page goes whatever
/// the mode (``dueAfter(_:)``).
@MainActor
final class TopPageHost {
    private(set) var views: [TopPageRoute: NSView] = [:]
    /// The provider key of each internal page view (a `LocalPageTab` key,
    /// so providers that read the key keep working).
    private var keys: [TopPageRoute: String] = [:]
    /// Since when each live page the window does not show is hidden (made, for one not shown yet).
    private var hiddenSince: [TopPageRoute: ContinuousClock.Instant] = [:]
    /// The records of released pages, until their view is made again.
    private(set) var released: [TopPageRoute: PageViewState] = [:]
    /// Records of rebuilt views, applied when the view shows (``didShow(_:)``).
    private var restoring: [TopPageRoute: PageViewState] = [:]
    /// A new view for a route and its provider key (nil for Home); nil when nothing serves the route.
    private let make: (TopPageRoute, WindowController?) -> (view: NSView, key: String?)?
    /// A route's view with its provider key is gone.
    private let closed: (TopPageRoute, String) -> Void
    /// The page's say in its discard: classic Home's view, an internal page's provider; nil: never discarded.
    private let discardable: (TopPageRoute, NSView) -> (any PageDiscardable)?
    private let titles: (TopPageRoute) -> String
    /// The `topPageDiscard` feature.
    private let discards: Bool
    /// How many hidden top pages stay live across all windows.
    private let hiddenLimit: Int
    /// Every window's host, this one too.
    private let hosts: () -> [TopPageHost]
    private let deadline: any PageDiscardDeadline
    private let planner = ContentDiscardPlanner()
    /// The window's node in the visibility tree; nil: the pages get no nodes (tests of the discard alone).
    private let windowNode: VisibilityNode?
    /// A page key's node, a child node (`TabContentCache.node(for:)`): the one its provider's views follow.
    private let pageNode: ((String) -> VisibilityNode)?
    /// Each internal page's node, held while its view lives: under ``windowNode``, visible only while
    /// the window shows the page (``contentDidChange(shown:)``), as a pane holds its selected tab's.
    private var nodes: [TopPageRoute: VisibilityNode] = [:]
    /// The clock (tests set it).
    var now: () -> ContinuousClock.Instant = { .now }
    /// Pages released so far (tests, diagnostics).
    private(set) var releasedCount = 0
    /// The `memory.saver` mode that scales each page's timeout (the memory coordinator hands it over).
    private(set) var saverMode: MemorySaverMode = .medium
    /// The coordinator's pressure level: at critical, hidden pages go whatever the mode (``dueAfter(_:)``).
    private(set) var pressure: MemoryPressureLevel = .normal
    private var memoryRegistration: MemoryConsumerRegistration?
    /// A page hidden less than this never goes for the budget: the person just left it, and a
    /// switch back to it must find it live, not rebuild it in the switch's turn (as
    /// `AgentPageHibernation.minimumHidden` keeps an agent page the person just left).
    static let budgetMinimumHidden: Duration = .seconds(30)

    init(make: @escaping (TopPageRoute, WindowController?) -> (view: NSView, key: String?)?,
         closed: @escaping (TopPageRoute, String) -> Void,
         discardable: @escaping (TopPageRoute, NSView) -> (any PageDiscardable)?, title: @escaping (TopPageRoute) -> String,
         discards: Bool, hiddenLimit: Int, hosts: @escaping () -> [TopPageHost], deadline: any PageDiscardDeadline,
         memory: (any MemoryConsumerRegistry)? = nil, windowNode: VisibilityNode? = nil,
         pageNode: ((String) -> VisibilityNode)? = nil) {
        self.make = make
        self.windowNode = windowNode
        self.pageNode = pageNode
        self.closed = closed
        self.discardable = discardable
        titles = title
        self.discards = discards
        self.hiddenLimit = hiddenLimit
        self.hosts = hosts
        self.deadline = deadline
        guard discards else { return }
        memoryRegistration = memory.map {
            MemoryConsumerRegistration(name: "top-page-discards", traits: ContentDiscardScheduler.memoryTraits, consumer: self, registry: $0)
        }
    }

    /// The app's top pages: classic Home, and an internal page's provider view in an
    /// `InternalPageView`. A provider that conforms to `PageDiscardable` sets its page's policy and
    /// view state; classic Home's view does. A page without one is never discarded. An internal page's
    /// key node (`TabContentCache.node(for:)`) hangs under `windowNode` while the page lives.
    convenience init(services: AppServices, windowNode: VisibilityNode) {
        self.init(make: { [weak services] route, window in services.flatMap { TopPageHost.makePage(route, in: window, services: $0) } },
                  closed: { [weak services] route, key in
                      if case .page(let id) = route { services?.pages.provider(id)?.tabClosed(key) }
                  },
                  discardable: { [weak services] route, view in
                      guard case .page(let id) = route else { return view as? TopHomePageView }
                      return services?.pages.provider(id) as? any PageDiscardable
                  },
                  title: { [weak services] route in
                      switch route {
                      case .home: HomeStrings.title
                      case .page(let id): services?.pages.provider(id)?.title ?? ""
                      }
                  },
                  discards: services.features.isEnabled(.topPageDiscard),
                  hiddenLimit: SubsystemBudget.forThisMac(gpuResidentAvailable: false).liveHiddenInternalPages,
                  hosts: { [weak services] in services?.windows.controllers.map { $0.topPages } ?? [] },
                  deadline: MainDeadline(owner: "TopPageHost.discard", workClass: .background, scheduler: services.mainDeadlines),
                  memory: services.memoryCoordinator, windowNode: windowNode,
                  pageNode: { [cache = services.cache] in cache.node(for: $0) })
    }

    private static func makePage(_ route: TopPageRoute, in window: WindowController?,
                                 services: AppServices) -> (view: NSView, key: String?)? {
        switch route {
        case .home:
            // The docked Home (cx-ebm.59.5) is the home workspace itself; only classic Home is a top page.
            guard HomeDock.classic else { return nil }
            return (TopHomePageView(services: services, windowKey: { [weak window] in window?.state.id ?? "" }), nil)
        case .page(let id):
            guard let provider = TopPages.provider(id, services: services) else { return nil }
            let key = LocalPageTab.makeKey(id)
            let content = provider.makeView(for: key, in: window)
            let page = InternalPageView(key: key, page: id, content: content, topBar: provider.makeTopBar(for: key),
                                        standInTitle: services.features.isEnabled(.pageStandIn) ? provider.title(for: key) : nil)
            page.navigate = services.pages.navigate
            return (page, key)
        }
    }

    /// The page's view, made on first show and after a release; nil when no provider serves the route.
    func view(for route: TopPageRoute, in window: WindowController?) -> NSView? {
        if let view = views[route] { return view }
        guard let made = make(route, window) else { return nil }
        views[route] = made.view
        keys[route] = made.key
        if let key = made.key, let windowNode, let pageNode {
            let node = pageNode(key)
            // It cannot throw: a page's node is a child, never above its window's.
            try? node.attach(to: windowNode)
            node.set(.hidden) // until the window shows it
            nodes[route] = node
        }
        hiddenSince[route] = now()
        if let state = released.removeValue(forKey: route) { restoring[route] = state }
        return made.view
    }

    /// The provider key of `route`'s view, once made.
    func key(for route: TopPageRoute) -> String? { keys[route] }

    /// The conversation classic Home shows: its live page's, else the one its discarded page showed.
    var homeSelection: ConversationID? {
        if let home = views[.home] as? TopHomePageView, let shown = home.shown { return shown }
        return (released[.home] ?? restoring[.home])?.selection.map { ConversationID($0) }
    }

    /// The page's title for the titlebar.
    func title(for route: TopPageRoute) -> String { titles(route) }

    /// Gives the page's primary input the keyboard (Home: the message box;
    /// a React page: its web content).
    func focus(_ route: TopPageRoute, in window: NSWindow?) {
        switch views[route] {
        case let home as TopHomePageView: home.focusPrimaryInput()
        case let page as InternalPageView: window?.makeFirstResponder(page.focusTarget)
        default: break
        }
    }

    /// `route`'s view is the window's content: a rebuilt page gets its record back from its owner
    /// (Home shows its conversation and search, and scrolls its list once the rows are in).
    func didShow(_ route: TopPageRoute) {
        guard let view = views[route], let state = restoring.removeValue(forKey: route) else { return }
        discardable(route, view)?.restoreViewState(state, in: view)
    }

    /// The window swapped its content (`WindowRootView.onContentChange`): the shown page is
    /// visible, every other live page is hidden from now on (an earlier hide keeps its instant), and
    /// each page's node says so.
    /// The plan runs on the deadline right after the swap's turn, never in it: a release tears a
    /// view down, which the switch's budget has no room for.
    func contentDidChange(shown: NSView?) {
        let at = now()
        for (route, view) in views {
            nodes[route]?.set(view === shown ? .visible : .hidden)
            if view === shown {
                hiddenSince[route] = nil
            } else if hiddenSince[route] == nil {
                hiddenSince[route] = at
            }
        }
        guard discards else { return }
        deadline.arm(after: .zero) { [weak self] in self?.plan() }
    }

    /// Content left the window (`WindowRootView.onContentWithdrawn`: a paint hold let its outgoing
    /// page go once the incoming one painted): a page that came due while it stayed on screen may go now.
    func contentDidLeaveWindow() {
        guard discards else { return }
        deadline.arm(after: .zero) { [weak self] in self?.plan() }
    }

    /// Holds every window's hidden pages to the budget, releases this window's due pages and arms
    /// its next deadline: the next page to come due, or the next page over the budget to grow old enough.
    func plan() {
        guard discards else { return }
        let budgetWait = Self.releaseOverLimit(hosts(), limit: hiddenLimit)
        let at = now()
        let reason: DiscardReason = pressure == .critical ? .urgent : .proactive
        var next = budgetWait
        for (route, since) in hiddenSince {
            guard let view = views[route], case .afterHidden(let pageTimeout) = policy(route, view),
                  let timeout = dueAfter(pageTimeout) else { continue }
            let remaining = timeout - (at - since)
            let wait: Duration
            if remaining > .zero {
                wait = remaining
            } else if view.window != nil || release(route, for: reason) {
                // Released, or still on screen (a paint hold keeps it): it leaving is the event
                // that plans again (``contentDidLeaveWindow()``).
                continue
            } else {
                // Kept (input the record does not keep): looked at again a timeout later, so a kept page wakes rarely.
                wait = timeout
            }
            next = min(next ?? wait, wait)
        }
        if let next {
            deadline.arm(after: next) { [weak self] in self?.plan() }
        } else {
            deadline.disarm()
        }
    }

    /// Releases hidden page `route` when the planner lets it go for `reason`: its record stays and
    /// its provider forgets the view. False when it stays (shown, still in the window, kept).
    @discardableResult
    func release(_ route: TopPageRoute, for reason: DiscardReason) -> Bool {
        // A page with no owner has nothing that records or restores it: it stays.
        guard discards, let view = views[route], let since = hiddenSince[route], view.window == nil,
              let owner = discardable(route, view) else { return false }
        var candidate = ContentDiscardPlanner.Candidate(key: route.rawValue, kind: .topPage, hiddenFor: (now() - since).seconds,
                                                        canRestore: owner.pageDiscardPolicy != .never)
        candidate.hasFormInput = owner.holdsUnsavedInput(view)
        guard planner.eligibility(of: candidate, setting: .fallback, for: reason).result == .eligible else { return false }
        var state = PageViewState(of: view)
        owner.saveViewState(view, into: &state)
        released[route] = state
        restoring[route] = nil
        close(route, view)
        releasedCount += 1
        return true
    }

    /// Holds the live hidden top pages of `hosts` to `limit`, as Chrome's `FrameEvictionManager`
    /// holds saved frames to its limit (components/viz/client/frame_eviction_manager.cc): the least
    /// recently hidden page that may go goes first; one that stays still counts. A page hidden less
    /// than ``budgetMinimumHidden`` waits.
    /// - Returns: While still over the limit, how soon the next waiting page is old enough; else nil.
    @discardableResult
    static func releaseOverLimit(_ hosts: [TopPageHost], limit: Int) -> Duration? {
        var hidden: [(host: TopPageHost, route: TopPageRoute, since: ContinuousClock.Instant)] = []
        for host in hosts {
            for (route, since) in host.hiddenSince where host.views[route] != nil { hidden.append((host, route, since)) }
        }
        var excess = hidden.count - limit
        guard excess > 0 else { return nil }
        var wait: Duration?
        for page in hidden.sorted(by: { $0.since < $1.since }) {
            guard excess > 0 else { return nil }
            let young = budgetMinimumHidden - (page.host.now() - page.since)
            if young > .zero {
                // Sorted oldest first, so this is the soonest of the waiting pages to grow old enough.
                wait = wait ?? young
            } else if page.host.release(page.route, for: .proactive) {
                excess -= 1
            }
        }
        return excess > 0 ? wait : nil
    }

    /// The window closed: every page view goes, and providers forget them.
    func teardown() {
        deadline.disarm()
        for (route, view) in views { close(route, view) }
        released.removeAll()
        restoring.removeAll()
    }

    /// How long a page whose policy says `timeout` waits hidden now. At critical pressure, whatever
    /// the mode: the sooner of `timeout` and ``budgetMinimumHidden``, as Chrome's urgent discarding
    /// takes hidden tabs before their proactive time (urgent_page_discarding_policy.cc). Else
    /// `timeout` in the Memory Saver mode; nil when the mode discards nothing proactively (off).
    private func dueAfter(_ timeout: Duration) -> Duration? {
        if pressure == .critical { return min(timeout, Self.budgetMinimumHidden) }
        return saverMode.proactiveTimeout(timeout)
    }

    /// The owner's policy; a page with no owner never goes.
    private func policy(_ route: TopPageRoute, _ view: NSView) -> PageDiscardPolicy {
        discardable(route, view)?.pageDiscardPolicy ?? .never
    }

    private func close(_ route: TopPageRoute, _ view: NSView) {
        view.removeFromSuperview()
        (view as? InternalPageView)?.detachContent() // while it lives: no page leaves its hierarchy in a dealloc
        nodes.removeValue(forKey: route)?.set(.hidden)
        views[route] = nil
        hiddenSince[route] = nil
        // The key goes first, so the provider no longer counts this page as open (`pageIsOpen`).
        if let key = keys.removeValue(forKey: route) { closed(route, key) }
    }
}

// The Memory Saver mode scales each page's timeout (Chrome's memory_saver_mode_policy.cc) and the
// level picks the proactive or the urgent pass: a change of either plans again after this turn, and
// the critical limit's release slice runs one pass. Lossy and holding no cap of its own, like the
// content discard schedulers.
extension TopPageHost: MemoryLevelConsumer, MemorySaverModeConsumer {
    func memorySaverModeDidChange(_ mode: MemorySaverMode) {
        guard mode != saverMode else { return }
        saverMode = mode
        guard discards else { return }
        deadline.arm(after: .zero) { [weak self] in self?.plan() }
    }

    func memoryLevelDidChange(_ level: MemoryPressureLevel) {
        guard level != pressure else { return }
        pressure = level
        guard discards else { return }
        deadline.arm(after: .zero) { [weak self] in self?.plan() }
    }

    func updateMemoryLimit(_ limit: MemoryLimit) {}

    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        if slice.limit.isCritical { plan() }
        return .done
    }

    /// Unknown: a page's views are not sampled on their own.
    var memoryUsage: MemoryUsage? { nil }
}
