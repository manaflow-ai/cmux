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
    let activity: () -> UInt64
    let isTrackingMenu: () -> Bool
    let timer: DemandTimer
    let parking = PageHostParking()
    var spare: PageWebView?
    var spareReady = false
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
        init(_ view: PageWebView) { self.view = view }
    }

    public init(policy: Policy = Policy(), options: PageEngineOptions = .standard,
                clock: any Clock<Duration> = ContinuousClock(),
                activity: @escaping () -> UInt64 = { ExpectedActivity.shared.total },
                isTrackingMenu: @escaping () -> Bool = { RunLoop.main.currentMode == .eventTracking }) {
        self.policy = policy
        self.options = options
        self.activity = activity
        self.isTrackingMenu = isTrackingMenu
        timer = DemandTimer(owner: "PageHostPool.build", clock: clock)
    }

    public var spareHost: PageWebView? { spare }
    public var isSpareReady: Bool { spare != nil && spareReady }
    public var isBuilding: Bool { building }
    public var claimedHosts: [PageWebView] {
        claimed = claimed.filter { $0.value.view != nil }
        return claimed.values.compactMap(\.view)
    }
    public var hostCount: Int { (spare == nil ? 0 : 1) + claimedHosts.count }
    public var mayBuild: Bool { shouldBuild }

    /// Claims the ready spare in this main-actor turn. A nil result means the caller should open
    /// the page with its ordinary initializer while the next spare continues warming.
    @discardableResult
    public func claim(_ descriptor: PageDescriptor, routes: [PageRoute], route: String? = nil,
                      documentAttributes: [String: String] = [:], surface: SurfaceKind? = nil,
                      dynamicResources: (any PageDynamicResourceSource)? = nil, window: NSWindow?,
                      focus: Bool = true) -> PageWebView? {
        guard PageServedHosts.pooledDescriptors.contains(descriptor) else { return nil }
        isLikely = true
        if target == nil, let window { follow(window) }
        guard let host = spare, spareReady, host.isPooled else {
            scheduleBuild()
            return nil
        }
        let start = ContinuousClock.now
        spare = nil
        spareReady = false
        claimed[ObjectIdentifier(host)] = WeakHost(host)
        host.removeFromSuperview()
        host.countsTouches = true
        host.shouldFocusOnAttach = focus
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
        if !host.touched, spare == nil, let content = target?.contentView {
            host.countsTouches = false
            park(host, in: content)
            spare = host
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
