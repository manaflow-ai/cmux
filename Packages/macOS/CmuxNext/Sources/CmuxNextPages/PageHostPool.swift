public import AppKit
public import CmuxNextSettings
public import CmuxNextWakeups

/// The one prewarmed page host of the app (plans/cmux-next/react-pages.md "Page shell"): a
/// pooled ``PageWebView`` that has loaded the page shell (`cmux-page://cmux.shell/`) and its page
/// chunks, parked out of sight in the key main window. A claim of a shell page
/// (``PageDescriptor/inShell``) takes it in one main-actor turn: no navigation and no load. Nil
/// means no warm host: the caller opens its page cold.
///
/// Prepared spare (decision a): the spare mounts the likely page ahead of its claim (the last
/// claimed shell page, or the page a caller names with ``prepare(_:routes:dynamicResources:size:)``
/// when its trigger is about to fire), parked at the claim's size when the caller knows it. A
/// claim of that page only hands it the session (`page.resume`); any other page is mounted on the
/// claim (the shell resets the prepared one first).
///
/// Hosts are one-shot: ``release(_:)`` retires the host (each has its own non-persistent website
/// data store, so the next host cannot see its storage), except a host that stayed untouched (no
/// user event, no page op after its claim), which is reset (`page.reset`) and parked again. At
/// most two hosts, so at most two WebContent processes (decision b): the spare is rebuilt while
/// one host is claimed, never while two are. A spare is built only while a shell page is likely,
/// only when the app is idle (no input, animation frame or terminal output for
/// ``Policy/idleInput``, no menu tracking), one step per run-loop turn (``Building``). Memory
/// pressure drops the spare.
@MainActor
public final class PageHostPool {
    public struct Policy: Sendable {
        public var idleInput: Duration = .milliseconds(750)
        /// Hosts alive at most (the spare and the claimed hosts).
        public var maximumHosts = 2
        /// The next spare prepares the last claimed shell page (decision a). Off: a generic shell.
        public var preparesLastClaimed = true
        public init() {}
    }

    /// One claim, for the claim bench and the debug verb.
    public struct Claim: Sendable, Equatable {
        public var page: String
        /// The host was parked in another window than the caller's.
        public var crossWindow: Bool
        /// The page was mounted in the spare ahead of the claim.
        public var prepared: Bool
        /// Main-thread time of the claim.
        public var milliseconds: Double
    }

    /// The page the spare mounts ahead of its claim.
    struct Likely {
        var descriptor: PageDescriptor
        var routes: [PageRoute]
        weak var dynamicResources: (any PageDynamicResourceSource)?
        var size: CGSize?
    }

    public static let maximumRecords = 64

    let policy: Policy
    let served: PageDescriptor
    let options: PageEngineOptions
    let activity: () -> UInt64
    let isTrackingMenu: () -> Bool
    let timer: DemandTimer
    let parking = PageHostParking()
    var spare: PageWebView?
    /// The spare booted its shell and loaded its page chunks.
    var spareReady = false
    /// The page mounted in the spare ahead of its claim (its claim answered).
    public internal(set) var preparedPage: String?
    /// The page whose prepare claim is in flight (the shell answers it before any later call).
    var preparingPage: String?
    var likely: Likely?
    var claimed: [ObjectIdentifier: WeakHost] = [:]
    var building = false
    var activityMark: UInt64 = 0
    var memoryPressure: (any DispatchSourceMemoryPressure)?
    var windowObservers: [any NSObjectProtocol] = []
    /// Whether a shell page is likely soon (a claim, ``noteLikely()`` or ``prepare(_:routes:dynamicResources:size:)``).
    public internal(set) var isLikely = false
    /// The window the spare parks in (the key main window, or the last one).
    public internal(set) weak var target: NSWindow?
    public internal(set) var claims: [Claim] = []
    /// Main-thread time of each spare build step (`pool.makeSpare.configure`, `.create`, `.park`, `.load`).
    public internal(set) var spans: [(name: String, milliseconds: Double)] = []
    /// Called after each build step (the app passes its bench spans).
    public var onSpan: ((String, Double) -> Void)?
    /// Called when a spare is parked, booted and loaded (tests and the debug verb).
    public var onSpareReady: ((PageWebView) -> Void)?
    /// Called when the spare has a page mounted ahead of its claim.
    public var onPrepared: ((PageWebView, String) -> Void)?

    final class WeakHost {
        weak var view: PageWebView?
        init(_ view: PageWebView) { self.view = view }
    }

    public init(policy: Policy = Policy(), served: PageDescriptor = .shell, options: PageEngineOptions = .standard,
                clock: any Clock<Duration> = ContinuousClock(),
                activity: @escaping () -> UInt64 = { ExpectedActivity.shared.total },
                isTrackingMenu: @escaping () -> Bool = { RunLoop.main.currentMode == .eventTracking }) {
        self.policy = policy
        self.served = served
        self.options = options
        self.activity = activity
        self.isTrackingMenu = isTrackingMenu
        timer = DemandTimer(owner: "PageHostPool.build", clock: clock)
    }

    /// The parked spare, if any (``isSpareReady`` once it can be claimed).
    public var spareHost: PageWebView? { spare }
    public var isSpareReady: Bool { spare != nil && spareReady }
    /// The claimed hosts still alive.
    public var claimedHosts: [PageWebView] {
        claimed = claimed.filter { $0.value.view != nil }
        return claimed.values.compactMap(\.view)
    }
    /// Hosts the pool keeps alive: the spare and the claimed hosts.
    public var hostCount: Int { (spare == nil ? 0 : 1) + claimedHosts.count }

    // MARK: Claim and release

    /// Takes the warm host for `descriptor` (a shell page) in this main-actor turn: out of its
    /// parking, bound to the page, the session sent (`page.resume` when the page was prepared in
    /// the spare, else `page.claim`). The caller adds it to its view at once. Nil (open cold) when
    /// no ready spare exists or the page is not a shell page. `mounted` gets the shell's answer.
    public func claim(_ descriptor: PageDescriptor, routes: [PageRoute], route: String? = nil, context: JSONValue = .null,
                      dynamicResources: (any PageDynamicResourceSource)? = nil, window: NSWindow?,
                      mounted: ((Result<JSONValue, PageError>) -> Void)? = nil) -> PageWebView? {
        isLikely = true
        if target == nil, let window { follow(window) }
        if policy.preparesLastClaimed, descriptor.inShell, likely?.descriptor.id != descriptor.id {
            likely = Likely(descriptor: descriptor, routes: routes, dynamicResources: dynamicResources, size: nil)
        }
        guard descriptor.inShell, let host = spare, spareReady, host.isPooled else {
            scheduleBuild()
            return nil
        }
        let start = ContinuousClock.now
        let prepared = (preparedPage ?? preparingPage) == descriptor.id
        spare = nil
        spareReady = false
        preparedPage = nil
        preparingPage = nil
        claimed[ObjectIdentifier(host)] = WeakHost(host)
        host.removeFromSuperview()
        host.countsTouches = true
        if prepared {
            if let dynamicResources { host.dynamicResources = dynamicResources }
            host.sendResume(routes: routes, route: route, context: context, reply: mounted)
        } else {
            host.retarget(descriptor: descriptor, routes: routes, dynamicResources: dynamicResources, route: route)
            host.sendClaim(context: context, reply: mounted)
        }
        record(Claim(page: descriptor.id, crossWindow: window != nil && window !== target, prepared: prepared,
                     milliseconds: Self.milliseconds(since: start)))
        scheduleBuild()
        return host
    }

    /// The caller is done with `host`. A used host is retired (closed and dropped); an untouched
    /// one is reset and parked again. The next spare follows at the next idle moment.
    public func release(_ host: PageWebView) {
        host.removeFromSuperview()
        guard claimed.removeValue(forKey: ObjectIdentifier(host)) != nil else {
            host.close()
            return
        }
        if !host.touched, spare == nil, let content = target?.contentView {
            host.resetShellPage()
            host.countsTouches = false
            park(host, in: content)
            spare = host
            spareReady = true
            prepareSpare()
            return
        }
        host.close()
        scheduleBuild()
    }

    /// A shell page is likely soon: build a spare at the next idle moment.
    public func noteLikely() {
        isLikely = true
        scheduleBuild()
    }

    /// `descriptor` is likely next (its trigger is about to fire, for example its menu opened):
    /// the spare mounts it ahead of its claim, parked at `size` when given (the claim's frame, so
    /// the first frame after the claim needs no new layout), else at its window's size. `routes`
    /// and `dynamicResources` serve the page while it is prepared; the claim's routes replace them.
    public func prepare(_ descriptor: PageDescriptor, routes: [PageRoute],
                        dynamicResources: (any PageDynamicResourceSource)? = nil, size: CGSize? = nil) {
        guard descriptor.inShell else { return }
        likely = Likely(descriptor: descriptor, routes: routes, dynamicResources: dynamicResources, size: size)
        isLikely = true
        if spareReady { prepareSpare() } else { scheduleBuild() }
    }

    /// Drops the spare (memory pressure, the last window closing). The next one waits for a claim.
    public func dropSpare() {
        timer.cancel()
        guard let host = spare else { return }
        spare = nil
        spareReady = false
        preparedPage = nil
        preparingPage = nil
        host.removeFromSuperview()
        host.close()
    }

    /// Mounts the likely page in the ready spare (or the generic shell when none is likely).
    func prepareSpare() {
        guard let host = spare, spareReady, let likely, preparingPage == nil,
              preparedPage != likely.descriptor.id else { return }
        if let size = likely.size {
            host.autoresizingMask = []
            host.frame = CGRect(origin: .zero, size: size)
        }
        preparingPage = likely.descriptor.id
        host.retarget(descriptor: likely.descriptor, routes: likely.routes, dynamicResources: likely.dynamicResources)
        host.sendClaim(prepare: true) { [weak self, weak host] result in
            guard let self, let host, host === self.spare, self.preparingPage == likely.descriptor.id else { return }
            self.preparingPage = nil
            if case .success = result {
                self.preparedPage = likely.descriptor.id
                self.onPrepared?(host, likely.descriptor.id)
            }
        }
    }

    func record(_ claim: Claim) {
        claims.append(claim)
        if claims.count > Self.maximumRecords { claims.removeFirst(claims.count - Self.maximumRecords) }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
