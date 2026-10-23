public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
public import CmuxNextWakeups

/// A small pool of prewarmed bundled React page hosts.
@MainActor
public final class PageHostPool {
    public struct Policy: Sendable {
        public var idleInput: Duration = .milliseconds(750)
        public var maximumHosts = 2

        public init() {}
    }

    /// One claim, retained for the claim benchmark and debug socket report.
    public struct Claim: Sendable, Equatable {
        public var page: String
        public var crossWindow: Bool
        public var spare: Bool
        public var milliseconds: Double
    }

    public static let maximumRecords = 64

    let policy: Policy
    let options: PageEngineOptions
    /// The Low Power Mode every spare renders by and follows.
    let lowPowerMode: LowPowerMode
    let activity: () -> UInt64
    /// Where the spare's pages are served from (tests pass a temporary root).
    let servedRoot: (PageDescriptor) -> URL?
    let isTrackingMenu: () -> Bool
    let timer: DemandTimer
    let parking = PageHostParking()
    var spare: PageWebView?
    var spareReady = false
    /// The ``rateGeneration`` the spare was made in.
    var spareGeneration = 0
    /// Bumped each time Low Power Mode turns on or off. A `.display` page's WebKit rate holds from
    /// the moment it is made: a preference written later did not change a shown page's cadence
    /// (cmux20, macOS 27, 120 Hz: near60 written, still 120 fps). So a spare or a returned host
    /// made in an earlier generation is never handed out again; the pool makes a new one.
    var rateGeneration = 0
    private var lowPowerObservation: LowPowerModeObservation?
    var claimed: [ObjectIdentifier: WeakHost] = [:]
    var building = false
    var activityMark: UInt64 = 0
    var memoryPressure: (any DispatchSourceMemoryPressure)?
    var windowObservers: [any NSObjectProtocol] = []
    public internal(set) var isLikely = false
    public internal(set) weak var target: NSWindow?
    public internal(set) var claims: [Claim] = []
    public internal(set) var spans: [(name: String, milliseconds: Double)] = []
    public var onSpan: ((String, Double) -> Void)?
    public var onSpareReady: ((PageWebView) -> Void)?

    final class WeakHost {
        weak var view: PageWebView?
        /// The ``PageHostPool/rateGeneration`` the host was made in.
        let generation: Int
        init(_ view: PageWebView, generation: Int) {
            self.view = view
            self.generation = generation
        }
    }

    /// `lowPowerMode` is the Low Power Mode every spare renders by: the app passes
    /// `LowPowerMode.system`, tests their own. When it changes, the pool drops its spare and makes
    /// a new one at the new rate (``rateGeneration``). `servedRoot` is where the spare's pages are
    /// served from: nil serves the bundled pages, tests pass a temporary root.
    public init(policy: Policy = Policy(), options: PageEngineOptions = .standard, lowPowerMode: LowPowerMode,
                clock: any Clock<Duration> = ContinuousClock(),
                activity: @escaping () -> UInt64 = { ExpectedActivity.shared.total },
                isTrackingMenu: @escaping () -> Bool = { RunLoop.main.currentMode == .eventTracking },
                servedRoot: ((PageDescriptor) -> URL?)? = nil) {
        self.policy = policy
        self.options = options
        self.lowPowerMode = lowPowerMode
        self.activity = activity
        self.servedRoot = servedRoot ?? { PageWebView.servedRoot(for: $0) }
        self.isTrackingMenu = isTrackingMenu
        timer = DemandTimer(owner: "PageHostPool.build", clock: clock)
        if options.renderRate == .display {
            lowPowerObservation = lowPowerMode.observe { [weak self] _ in self?.lowPowerModeChanged() }
        }
    }

    /// A spare made at the old rate would keep it: drop it and build one at the new rate.
    func lowPowerModeChanged() {
        rateGeneration += 1
        dropSpare()
        scheduleBuild()
    }

    public var isSpareReady: Bool { spare != nil && spareReady }
    public var isBuilding: Bool { building }
    public var claimedHosts: [PageWebView] {
        claimed = claimed.filter { $0.value.view != nil }
        return claimed.values.compactMap(\.view)
    }
    public var hostCount: Int { (spare == nil ? 0 : 1) + claimedHosts.count }

    /// Claims the ready spare in this main-actor turn. A nil result means the caller should open
    /// the page with its ordinary initializer while the next spare continues warming.
    @discardableResult
    public func claim(_ descriptor: PageDescriptor, routes: [PageRoute], route: String? = nil,
                      documentAttributes: [String: String] = [:], options: PageEngineOptions = .standard,
                      surface: SurfaceKind? = nil,
                      dynamicResources: (any PageDynamicResourceSource)? = nil, window: NSWindow?,
                      focus: Bool = true) -> PageWebView? {
        guard PageServedHosts.pooledDescriptors.contains(descriptor) else { return nil }
        // Spares are WebKit views: a page that shows in Chromium is made fresh (PageWebView+Chromium).
        let decision = PageWebView.engineDecision(for: descriptor, options: options)
        guard decision.engine == .webKit else { return nil }
        isLikely = true
        if target == nil, let window { follow(window) }
        guard let host = spare, spareReady, host.isPooled else {
            scheduleBuild()
            return nil
        }
        let start = ContinuousClock.now
        spare = nil
        spareReady = false
        claimed[ObjectIdentifier(host)] = WeakHost(host, generation: spareGeneration)
        host.removeFromSuperview()
        host.countsTouches = true
        host.shouldFocusOnAttach = focus
        host.engineDecision = decision
        _ = host.retarget(descriptor: descriptor, routes: routes, route: route,
                          documentAttributes: documentAttributes, surface: surface,
                          dynamicResources: dynamicResources)
        record(Claim(page: descriptor.id, crossWindow: window != nil && window !== target,
                     spare: true, milliseconds: Self.milliseconds(since: start)))
        scheduleBuild()
        return host
    }

    /// Releases a claimed host. Only an untouched host made at the current rate (``rateGeneration``)
    /// may return to the spare slot.
    public func release(_ host: PageWebView) {
        host.removeFromSuperview()
        guard let entry = claimed.removeValue(forKey: ObjectIdentifier(host)) else {
            host.close()
            return
        }
        if !host.touched, spare == nil, entry.generation == rateGeneration, let content = target?.contentView {
            host.countsTouches = false
            park(host, in: content)
            spare = host
            spareGeneration = entry.generation
            spareReady = false
            Task { @MainActor [weak self, weak host] in
                await host?.resetPooledPage()
                guard let self, let host, self.spare === host else { return }
                self.spareReady = true
                self.onSpareReady?(host)
            }
            return
        }
        host.close()
        scheduleBuild()
    }

    /// Marks one of the bundled page surfaces as likely to open soon.
    public func noteLikely() {
        isLikely = true
        scheduleBuild()
    }

    /// Drops the parked spare, for memory pressure or teardown.
    public func dropSpare() {
        timer.cancel()
        guard let host = spare else { return }
        spare = nil
        spareReady = false
        host.removeFromSuperview()
        host.close()
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
