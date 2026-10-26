import AppKit
import CmuxNextFeatures
import CmuxNextHibernation
import CmuxNextMemory
import CmuxNextSettings
import CmuxNextWakeups

/// What a window's ``TopPageHost`` asks of the app (``AppTopPages``; a fake in tests).
@MainActor
protocol TopPageMaking: AnyObject {
    /// A new view for `route` and its provider key (nil for Home); nil when nothing serves the route.
    func makePage(_ route: TopPageRoute, in window: WindowController?) -> (view: NSView, key: String?)?
    /// `route`'s view with provider key `key` is gone.
    func pageClosed(_ route: TopPageRoute, key: String)
    /// The page's say in its discard: classic Home's view, an internal page's provider; nil takes the defaults.
    func discardable(_ route: TopPageRoute, view: NSView) -> (any TopPageDiscardable)?
    /// The page's title for the titlebar.
    func title(for route: TopPageRoute) -> String
}

/// One window's top pages: one view per route, made on first show. A page the window stops showing
/// stays live, so it keeps its state when the window switches to a workspace and back, until its
/// discard policy (``TopPageDiscardPolicy``) says it may go. Then its view is released and a
/// ``TopPageViewState`` stays; the next show builds the page again and restores it. Behind the
/// `topPageDiscard` feature (default off); off, every view stays for the window's life as before.
///
/// Live hidden top pages are also held to the Mac's budget across all windows
/// (`SubsystemBudget.liveHiddenInternalPages`, ``releaseOverLimit(_:limit:)``). Eligibility is the
/// one planner's (`ContentDiscardPlanner`, kind `topPage`), so typed text no model keeps holds a
/// page at any pressure (the lead rule's form input). Events only: content swaps, and one deadline
/// per window for its next page to come due.
@MainActor
final class TopPageHost {
    private let pages: any TopPageMaking
    private(set) var views: [TopPageRoute: NSView] = [:]
    /// The provider key of each internal page view (a `LocalPageTab` key,
    /// so providers that read the key keep working).
    private var keys: [TopPageRoute: String] = [:]
    /// Since when each live page the window does not show is hidden (made, for one not shown yet).
    private var hiddenSince: [TopPageRoute: ContinuousClock.Instant] = [:]
    /// The records of released pages, until their view is made again.
    private(set) var released: [TopPageRoute: TopPageViewState] = [:]
    /// Records of rebuilt views, applied when the view shows (``didShow(_:)``).
    private var restoring: [TopPageRoute: TopPageViewState] = [:]
    /// The `topPageDiscard` feature.
    private let discards: Bool
    /// How many hidden top pages stay live across all windows.
    private let hiddenLimit: Int
    /// Every window's host, this one too.
    private let hosts: () -> [TopPageHost]
    private let deadline: any TopPageDiscardDeadline
    private let planner = ContentDiscardPlanner()
    /// The clock (tests set it).
    var now: () -> ContinuousClock.Instant = { .now }
    /// Pages released so far (tests, diagnostics).
    private(set) var releasedCount = 0
    /// How soon a due page still in the window (an outgoing view a paint hold keeps) is looked at again.
    static let onScreenRecheck: Duration = .seconds(1)

    init(pages: any TopPageMaking, discards: Bool, hiddenLimit: Int, hosts: @escaping () -> [TopPageHost],
         deadline: any TopPageDiscardDeadline) {
        self.pages = pages
        self.discards = discards
        self.hiddenLimit = hiddenLimit
        self.hosts = hosts
        self.deadline = deadline
    }

    convenience init(services: AppServices) {
        self.init(pages: AppTopPages(services: services),
                  discards: services.features.isEnabled(.topPageDiscard),
                  hiddenLimit: SubsystemBudget.forThisMac(gpuResidentAvailable: false).liveHiddenInternalPages,
                  hosts: { [weak services] in services?.windows.controllers.map { $0.topPages } ?? [] },
                  deadline: DemandTimer(owner: "TopPageHost.discard"))
    }

    /// The page's view, made on first show and after a release; nil when no provider serves the route.
    func view(for route: TopPageRoute, in window: WindowController?) -> NSView? {
        if let view = views[route] { return view }
        guard let made = pages.makePage(route, in: window) else { return nil }
        views[route] = made.view
        keys[route] = made.key
        hiddenSince[route] = now()
        if let state = released.removeValue(forKey: route) { restoring[route] = state }
        return made.view
    }

    /// The provider key of `route`'s view, once made.
    func key(for route: TopPageRoute) -> String? { keys[route] }

    /// The page's title for the titlebar.
    func title(for route: TopPageRoute) -> String { pages.title(for: route) }

    /// Gives the page's primary input the keyboard (Home: the message box;
    /// a React page: its web content).
    func focus(_ route: TopPageRoute, in window: NSWindow?) {
        switch views[route] {
        case let home as TopHomePageView: home.focusPrimaryInput()
        case let page as InternalPageView: window?.makeFirstResponder(page.focusTarget)
        default: break
        }
    }

    /// `route`'s view is the window's content: a rebuilt page gets its record back, the page's own
    /// part first (Home shows its conversation), then the scroll offsets on the laid out view.
    func didShow(_ route: TopPageRoute) {
        guard let view = views[route], let state = restoring.removeValue(forKey: route) else { return }
        pages.discardable(route, view: view)?.restoreViewState(state, in: view)
        view.layoutSubtreeIfNeeded()
        state.restoreScroll(in: view)
    }

    /// The window swapped its content (`WindowRootView.onContentChange`): the shown page is
    /// visible, every other live page is hidden from now on (an earlier hide keeps its instant).
    /// The plan runs on the deadline right after the swap's turn, never in it: a release tears a
    /// view down, which the switch's budget has no room for.
    func contentDidChange(shown: NSView?) {
        let at = now()
        for (route, view) in views {
            if view === shown {
                hiddenSince[route] = nil
            } else if hiddenSince[route] == nil {
                hiddenSince[route] = at
            }
        }
        guard discards else { return }
        deadline.arm(after: .zero) { [weak self] in self?.plan() }
    }

    /// Holds every window's hidden pages to the budget, then releases this window's due pages
    /// and arms its next deadline.
    func plan() {
        guard discards else { return }
        Self.releaseOverLimit(hosts(), limit: hiddenLimit)
        replan()
    }

    /// Releases this window's pages past their policy and arms one deadline for the next.
    func replan() {
        guard discards else { return }
        let at = now()
        var next: Duration?
        for (route, since) in hiddenSince {
            guard let view = views[route], case .afterHidden(let timeout) = policy(route, view) else { continue }
            let remaining = timeout - (at - since)
            let wait: Duration
            if remaining > .zero {
                wait = remaining
            } else if view.window != nil {
                wait = Self.onScreenRecheck
            } else if release(route, for: .proactive) {
                continue
            } else {
                // Kept (typed text): looked at again a timeout later, so a kept page wakes rarely.
                wait = timeout
            }
            next = min(next ?? wait, wait)
        }
        if let next {
            deadline.arm(after: next) { [weak self] in self?.replan() }
        } else {
            deadline.disarm()
        }
    }

    /// Releases hidden page `route` when the planner lets it go for `reason`: its record stays and
    /// its provider forgets the view. False when it stays (shown, still in the window, kept).
    @discardableResult
    func release(_ route: TopPageRoute, for reason: DiscardReason) -> Bool {
        guard discards, let view = views[route], let since = hiddenSince[route], view.window == nil else { return false }
        let owner = pages.discardable(route, view: view)
        var candidate = ContentDiscardPlanner.Candidate(key: route.rawValue, kind: .topPage, hiddenFor: (now() - since).seconds,
                                                        canRestore: (owner?.topPageDiscardPolicy ?? .standard) != .never)
        candidate.hasFormInput = TopPageViewState.holdsTypedText(view) || owner?.holdsUnsavedInput(view) == true
        guard planner.eligibility(of: candidate, setting: .fallback, for: reason).result == .eligible else { return false }
        var state = TopPageViewState(of: view)
        owner?.saveViewState(view, into: &state)
        released[route] = state
        restoring[route] = nil
        close(route, view)
        releasedCount += 1
        return true
    }

    /// Holds the live hidden top pages of `hosts` to `limit`, as Chrome's `FrameEvictionManager`
    /// holds saved frames to its limit (components/viz/client/frame_eviction_manager.cc): the least
    /// recently hidden page that may go goes first; one that stays still counts.
    static func releaseOverLimit(_ hosts: [TopPageHost], limit: Int) {
        var hidden: [(host: TopPageHost, route: TopPageRoute, since: ContinuousClock.Instant)] = []
        for host in hosts {
            for (route, since) in host.hiddenSince where host.views[route] != nil { hidden.append((host, route, since)) }
        }
        var excess = hidden.count - limit
        guard excess > 0 else { return }
        for page in hidden.sorted(by: { $0.since < $1.since }) {
            guard excess > 0 else { return }
            if page.host.release(page.route, for: .proactive) { excess -= 1 }
        }
    }

    /// The window closed: every page view goes, and providers forget them.
    func teardown() {
        deadline.disarm()
        for (route, view) in views { close(route, view) }
        released.removeAll()
        restoring.removeAll()
    }

    private func policy(_ route: TopPageRoute, _ view: NSView) -> TopPageDiscardPolicy {
        pages.discardable(route, view: view)?.topPageDiscardPolicy ?? .standard
    }

    private func close(_ route: TopPageRoute, _ view: NSView) {
        view.removeFromSuperview()
        views[route] = nil
        hiddenSince[route] = nil
        // The key goes first, so the provider no longer counts this page as open (`pageIsOpen`).
        if let key = keys.removeValue(forKey: route) { pages.pageClosed(route, key: key) }
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
