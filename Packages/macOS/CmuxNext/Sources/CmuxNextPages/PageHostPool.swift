public import AppKit
public import CmuxNextCompat
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
    /// The options most recently requested by a page claim, used when deciding whether another
    /// WebKit spare is useful. It starts with the pool's default warmup options.
    var latestClaimOptions: PageEngineOptions
    let activity: () -> UInt64
    let isTrackingMenu: () -> Bool
    let engineDecision: (PageDescriptor, PageEngineOptions) -> PageEngineDecision
    let timer: DemandTimer
    let parking = PageHostParking()
    var spare: PageWebView?
    var spareReady = false
    var claimed: [ObjectIdentifier: WeakHost] = [:]
    var building = false
    var activityMark: UInt64 = 0
    /// The app's memory pressure events; a warning or critical level drops the spare.
    let memoryPressure: MemoryPressureEvents
    var pressureObservation: MainActorHandlerRegistration<MemoryPressureLevel>?
    var windowObservers: [any NSObjectProtocol] = []
    public internal(set) var isLikely = false
    public internal(set) weak var target: NSWindow?
    public internal(set) var claims: [Claim] = []
    public internal(set) var spans: [(name: String, milliseconds: Double)] = []
    public var onSpan: ((String, Double) -> Void)?
    public var onSpareReady: ((PageWebView) -> Void)?

    final class WeakHost {
        weak var view: PageWebView?
        init(_ view: PageWebView) { self.view = view }
    }

    /// - Parameter memoryPressure: the app's one memory pressure service (a test passes events from a
    ///   source it drives); a warning or critical level drops the parked spare.
    public init(memoryPressure: MemoryPressureEvents, policy: Policy = Policy(), options: PageEngineOptions = .standard,
                clock: any Clock<Duration> = ContinuousClock(),
                activity: @escaping () -> UInt64 = { ExpectedActivity.shared.total },
                isTrackingMenu: @escaping () -> Bool = { RunLoop.main.currentMode == .eventTracking },
                engineDecision: @escaping (PageDescriptor, PageEngineOptions) -> PageEngineDecision = {
                    PageWebView.engineDecision(for: $0, options: $1)
                }) {
        self.memoryPressure = memoryPressure
        self.policy = policy
        latestClaimOptions = options
        self.activity = activity
        self.isTrackingMenu = isTrackingMenu
        self.engineDecision = engineDecision
        timer = DemandTimer(owner: "PageHostPool.build", clock: clock)
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
        latestClaimOptions = options
        let decision = engineDecision(descriptor, options)
        guard decision.engine == .webKit else {
            // A Chromium claim cannot use the parked WebKit view. Cancel any queued/building
            // WebKit warmup too; the next WebKit claim will arm it with its own options.
            dropSpare()
            return nil
        }
        isLikely = true
        if target == nil, let window { follow(window) }
        guard let host = spare, spareReady, host.isPooled else {
            scheduleBuild()
            return nil
        }
        let start = ContinuousClock.now
        spare = nil
        spareReady = false
        host.isHidden = false
        claimed[ObjectIdentifier(host)] = WeakHost(host)
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

    /// Releases a claimed host. Only an untouched host may return to the spare slot.
    public func release(_ host: PageWebView) {
        host.removeFromSuperview()
        guard claimed.removeValue(forKey: ObjectIdentifier(host)) != nil else {
            host.close()
            return
        }
        if !host.touched, spare == nil, let content = target?.contentView, canUseSpare {
            host.countsTouches = false
            park(host, in: content)
            spare = host
            spareReady = false
            Task { @MainActor [weak self, weak host] in
                await host?.resetPooledPage()
                guard let self, let host, self.spare === host else { return }
                self.suspendAfterPaint(host)
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
