public import AppKit
public import CmuxNextSettings
public import CmuxNextWakeups

/// The one prewarmed page host of the app (plans/cmux-next/react-pages.md "Page shell"): a
/// pooled ``PageWebView`` that has loaded the page shell (`cmux-page://cmux.shell/`) and its page
/// chunks, parked out of sight in the key main window. A claim of a shell page
/// (``PageDescriptor/inShell``) takes it in one main-actor turn: no navigation and no load, the
/// page mounts on `page.claim`. Nil means no warm host: the caller opens its page cold.
///
/// Hosts are one-shot: ``release(_:)`` retires the host (each has its own non-persistent website
/// data store, so the next host cannot see its storage), except a host that stayed untouched (no
/// user event, no page op), which is reset (`page.reset`) and parked again. One host total: the
/// next spare is built only after the claimed host is released, only while a shell page is
/// likely, and only when the app is idle (no input, animation frame or terminal output for
/// ``Policy/idleInput``, no menu tracking). Memory pressure drops the spare.
@MainActor
public final class PageHostPool {
    public struct Policy: Sendable {
        public var idleInput: Duration = .milliseconds(750)
        /// Stub: the next spare does not prepare anything yet.
        public var preparesLastClaimed = true
        public init() {}
    }

    /// One claim, for the claim bench and the debug verb.
    public struct Claim: Sendable, Equatable {
        public var page: String
        /// The host was parked in another window than the caller's.
        public var crossWindow: Bool
        /// Stub: no claim is prepared yet.
        public var prepared = false
        /// Main-thread time of the claim.
        public var milliseconds: Double
    }

    public static let maximumRecords = 64

    private let policy: Policy
    private let makeHost: () -> PageWebView?
    private let activity: () -> UInt64
    private let isTrackingMenu: () -> Bool
    private let timer: DemandTimer
    private let parking = PageHostParking()
    private var spare: PageWebView?
    /// The spare finished loading the shell and its page chunks.
    private var spareReady = false
    private weak var claimed: PageWebView?
    private var building = false
    private var activityMark: UInt64 = 0
    private var memoryPressure: (any DispatchSourceMemoryPressure)?
    private var windowObservers: [any NSObjectProtocol] = []
    /// Whether a shell page is likely soon (a claim was asked for this session, or ``noteLikely()``).
    public private(set) var isLikely = false
    /// The window the spare parks in (the key main window, or the last one).
    public private(set) weak var target: NSWindow?
    public private(set) var claims: [Claim] = []
    /// Main-thread time of each spare build step (`pool.makeSpare`, `pool.makeSpare.park`).
    public private(set) var spans: [(name: String, milliseconds: Double)] = []
    /// Called after each build step (the app passes its bench spans).
    public var onSpan: ((String, Double) -> Void)?
    /// Called when a spare is parked and loaded (tests and the debug verb).
    public var onSpareReady: ((PageWebView) -> Void)?

    public init(policy: Policy = Policy(), clock: any Clock<Duration> = ContinuousClock(),
                activity: @escaping () -> UInt64 = { ExpectedActivity.shared.total },
                isTrackingMenu: @escaping () -> Bool = { RunLoop.main.currentMode == .eventTracking },
                makeHost: @escaping () -> PageWebView? = { PageWebView(pooledHost: .shell) }) {
        self.policy = policy
        self.makeHost = makeHost
        self.activity = activity
        self.isTrackingMenu = isTrackingMenu
        timer = DemandTimer(owner: "PageHostPool.build", clock: clock)
    }

    /// The parked spare, if any (``isSpareReady`` once it can be claimed).
    public var spareHost: PageWebView? { spare }
    public var isSpareReady: Bool { spare != nil && spareReady }
    /// The claimed hosts still alive (stub: at most one).
    public var claimedHosts: [PageWebView] { claimed.map { [$0] } ?? [] }
    /// The claimed host, if any.
    public var claimedHost: PageWebView? { claimed }

    // MARK: Claim and release

    /// Takes the warm host for `descriptor` (a shell page) in this main-actor turn: out of its
    /// parking, bound to the page, `page.claim` sent. The caller adds it to its view at once.
    /// Nil (open cold) when no loaded spare exists or the page is not a shell page. `mounted` gets
    /// the shell's answer to the claim (the page is mounted, or why not).
    public func claim(_ descriptor: PageDescriptor, routes: [PageRoute], route: String? = nil, context: JSONValue = .null,
                      dynamicResources: (any PageDynamicResourceSource)? = nil, window: NSWindow?,
                      mounted: ((Result<JSONValue, PageError>) -> Void)? = nil) -> PageWebView? {
        isLikely = true
        if target == nil, let window { follow(window) }
        guard descriptor.inShell, let host = spare, spareReady, host.claimsInShell(descriptor) else {
            scheduleBuild()
            return nil
        }
        let start = ContinuousClock.now
        spare = nil
        spareReady = false
        claimed = host
        host.removeFromSuperview()
        host.retarget(descriptor: descriptor, routes: routes, dynamicResources: dynamicResources, route: route)
        host.sendClaim(context: context, reply: mounted)
        record(Claim(page: descriptor.id, crossWindow: window != nil && window !== target,
                     milliseconds: Self.milliseconds(since: start)))
        return host
    }

    /// The caller is done with `host`. A used host is retired (closed and dropped); an untouched
    /// one is reset and parked again. The next spare follows at the next idle moment.
    public func release(_ host: PageWebView) {
        host.removeFromSuperview()
        guard host === claimed else {
            host.close()
            return
        }
        claimed = nil
        if !host.touched, spare == nil, let content = target?.contentView {
            host.resetShellPage()
            park(host, in: content)
            spare = host
            spareReady = true
            return
        }
        host.close()
        scheduleBuild()
    }

    /// The page mounted in the spare ahead of its claim (stub: none yet).
    public var preparedPage: String? { nil }
    /// Called when the spare has a page mounted ahead of its claim.
    public var onPrepared: ((PageWebView, String) -> Void)?
    /// Hosts the pool keeps alive: the spare and the claimed hosts.
    public var hostCount: Int { (spare == nil ? 0 : 1) + (claimed == nil ? 0 : 1) }
    /// Whether the pool may build a spare now.
    public var mayBuild: Bool { shouldBuild }

    /// `descriptor` is likely next (its trigger is about to fire): stub, only marks a shell page likely.
    public func prepare(_ descriptor: PageDescriptor, routes: [PageRoute],
                        dynamicResources: (any PageDynamicResourceSource)? = nil, size: CGSize? = nil) {
        noteLikely()
    }

    /// A shell page is likely soon: build a spare at the next idle moment.
    public func noteLikely() {
        isLikely = true
        scheduleBuild()
    }

    /// Drops the spare (memory pressure, the last window closing). The next one waits for a claim.
    public func dropSpare() {
        timer.cancel()
        guard let host = spare else { return }
        spare = nil
        spareReady = false
        host.removeFromSuperview()
        host.close()
    }

    // MARK: Windows

    /// Parks the spare in `window`: moves it there (a reparent, no reload), or builds one at the
    /// next idle moment.
    public func follow(_ window: NSWindow) {
        guard window !== target else { return }
        target = window
        if let spare, let content = window.contentView { park(spare, in: content) }
        scheduleBuild()
    }

    /// Follows the key main window (`isMainWindow` tells the app's main windows from panels and
    /// popovers); when the target closes, the spare moves to `fallback()` or is dropped.
    public func start(isMainWindow: @escaping @MainActor (NSWindow) -> Bool,
                      fallback: @escaping @MainActor (NSWindow) -> NSWindow?) {
        guard windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
            [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, isMainWindow(window) else { return }
                self.follow(window)
            }
        })
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, window === self.target else { return }
                if let next = fallback(window) { self.follow(next) } else { self.dropSpare(); self.target = nil }
            }
        })
    }

    private func park(_ host: PageWebView, in content: NSView) {
        if parking.superview !== content {
            parking.frame = content.bounds
            parking.autoresizingMask = [.width, .height]
            content.addSubview(parking, positioned: .below, relativeTo: nil)
        }
        host.frame = parking.bounds
        host.autoresizingMask = [.width, .height]
        if host.superview !== parking { parking.addSubview(host) }
    }

    private func record(_ claim: Claim) {
        claims.append(claim)
        if claims.count > Self.maximumRecords { claims.removeFirst(claims.count - Self.maximumRecords) }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    // MARK: Building

    private var shouldBuild: Bool { isLikely && spare == nil && claimed == nil && !building && target != nil }

    /// Arms the idle deadline: it builds only after a whole quiet period (no change of the app's
    /// activity counters: input, animation frames, terminal output; no menu tracking).
    private func scheduleBuild() {
        guard shouldBuild else { return }
        watchMemoryPressure()
        armIdle()
    }

    private func armIdle() {
        activityMark = activity()
        timer.schedule(after: policy.idleInput) { @MainActor [weak self] in self?.idleDeadline() }
    }

    private func idleDeadline() {
        guard shouldBuild else { return }
        guard !isTrackingMenu(), activity() == activityMark else { return armIdle() }
        building = true
        // task-owner: one spare build; each step is its own main-actor turn so no frame holds two
        Task { @MainActor [weak self] in await self?.build() }
    }

    /// Builds the spare in steps, one main-actor turn each: make the host (its web view and load
    /// request), then park it in the target window. Each step's time goes to ``spans``.
    private func build() async {
        defer { building = false }
        let host = measure("pool.makeSpare") { makeHost() }
        guard let host else { return }
        await Task.yield()
        guard isLikely, spare == nil, claimed == nil, let content = target?.contentView else {
            host.close()
            return
        }
        measure("pool.makeSpare.park") { park(host, in: content) }
        spare = host
        await host.waitUntilLoaded()
        guard host.isLoaded else {
            // The shell did not load (a missing build): no spare; callers open cold.
            if spare === host { dropSpare() }
            return
        }
        guard await host.preloadShellPages() else {
            // The shell never booted: no spare; callers open cold.
            if spare === host { dropSpare() }
            return
        }
        guard spare === host else { return }
        spareReady = true
        onSpareReady?(host)
    }

    private func measure<T>(_ name: String, _ body: () -> T) -> T {
        let start = ContinuousClock.now
        let value = body()
        let milliseconds = Self.milliseconds(since: start)
        spans.append((name, milliseconds))
        if spans.count > Self.maximumRecords { spans.removeFirst(spans.count - Self.maximumRecords) }
        onSpan?(name, milliseconds)
        return value
    }

    private func watchMemoryPressure() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.dropSpare() }
        }
        source.resume()
        memoryPressure = source
    }
}

/// Where the spare waits: in the target window (WebKit renders only views in a window and not
/// hidden), fully transparent, never hit by the mouse, out of the accessibility tree (the
/// parking of the new tab spare, NewTabSparePool). A claim reparents the host out of it.
final class PageHostParking: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}
