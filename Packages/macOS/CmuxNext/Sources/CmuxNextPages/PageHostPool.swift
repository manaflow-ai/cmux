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
        /// No spare before a pooled page first showed this session (feature `pageRendererAtFirstShow`):
        /// Chrome's `PreloadMode::kPreloadOnMakeVisible`, which preloads the next top-chrome WebUI only
        /// once one was made visible (chrome/browser/ui/webui/top_chrome/webui_contents_preload_manager.cc).
        /// A session that never opens Settings, History or Cloud then runs no renderer for them.
        public var preloadOnMakeVisible: Bool

        public init(preloadOnMakeVisible: Bool = false) {
            self.preloadOnMakeVisible = preloadOnMakeVisible
        }
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
    /// The idle deadline of the next spare build: background work on the app's deadline scheduler, so a spare
    /// nobody sees waits behind input and every visible task (Chrome's kBestEffort,
    /// content/browser/scheduler/browser_task_queues.h).
    let timer: MainDeadline
    /// The pool's deadline scheduler: each step of a build runs in the body of one background task of its
    /// ``MainDeadlineScheduler/work`` (``step(_:_:)``), and the spare page it makes runs its own deadlines on it.
    let deadlines: MainDeadlineScheduler
    let parking = PageHostParking()
    var spare: PageWebView?
    var spareReady = false
    var claimed: [ObjectIdentifier: WeakHost] = [:]
    var building = false
    /// Normal came back while a build was in flight (`refillSpare`): that build lost its spare to the
    /// pressure, so the pool builds again when it ends.
    var refillAfterBuild = false
    /// A pooled page the spare could serve was made visible this session (``Policy/preloadOnMakeVisible``).
    var madeVisible = false
    var activityMark: UInt64 = 0
    /// The pool's memory consumer: warning or critical drops the spare, and none is built or parked
    /// again until normal (Chrome's spare rule, ``SpareMemoryConsumer``).
    var spareMemory: SpareMemoryConsumer?
    var windowObservers: [MainActorObservation] = []
    public internal(set) var isLikely = false
    public internal(set) weak var target: NSWindow?
    public internal(set) var claims: [Claim] = []
    public internal(set) var spans: [(name: String, milliseconds: Double)] = []
    public var onSpan: ((String, Double) -> Void)?
    public var onSpareReady: ((PageWebView) -> Void)?
    /// The windows' frame-aligned pointer input (feature `pointerFrameHover`): a claimed host gets it
    /// for its popup's rows, as a page ``WebUIHost`` opens does. Nil: each move hovers at once.
    let hoverFrameInput: FrameInputCoalescers?
    /// The frame a claimed host delivers its router envelopes on, as a page ``WebUIHost`` opens does
    /// (``WebUIHost/scriptFrames``, `pageScriptFrames`). Nil: each envelope is its own script.
    package var scriptFrames: PageScriptFrame?

    final class WeakHost {
        weak var view: PageWebView?
        init(_ view: PageWebView) { self.view = view }
    }

    /// - Parameters:
    ///   - memory: the app's memory coordinator (a test passes one over a source it drives); the pool registers
    ///     its spare with it at once.
    ///   - deadlines: The app's one deadline scheduler (`AppServices.mainDeadlines`): the build's idle deadline
    ///     and its steps run on it as background work. A test leaves the default, its own.
    public init(memory: any MemoryConsumerRegistry, policy: Policy = Policy(), options: PageEngineOptions = .standard,
                deadlines: MainDeadlineScheduler = MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())),
                activity: @escaping () -> UInt64 = { ExpectedActivity.shared.total },
                isTrackingMenu: @escaping () -> Bool = { RunLoop.main.currentMode == .eventTracking },
                hoverFrameInput: FrameInputCoalescers? = nil) {
        self.hoverFrameInput = hoverFrameInput
        self.policy = policy
        self.options = options
        self.activity = activity
        self.isTrackingMenu = isTrackingMenu
        timer = MainDeadline(owner: "PageHostPool.build", workClass: .background, scheduler: deadlines)
        self.deadlines = deadlines
        spareMemory = SpareMemoryConsumer(
            name: "page-host-spare", registry: memory, spares: { [weak self] in self?.spare == nil ? 0 : 1 },
            drop: { [weak self] in self?.dropSpare() }, refill: { [weak self] in self?.refillSpare() })
    }

    /// Whether memory pressure lets the pool keep, build or park a spare now (normal only).
    var allowsSpare: Bool { spareMemory?.allowsSpares ?? true }

    public var isSpareReady: Bool { spare != nil && spareReady }
    /// The spare host while one waits, ready or still loading (`debug.memory` spares).
    public var spareHost: PageWebView? { spare }
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
        madeVisible = true
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
        host.popupHoverFrameInput = hoverFrameInput
        if let scriptFrames, !host.deliversOnFrames { host.deliverOnFrames(scriptFrames) }
        host.engineDecision = decision
        _ = host.retarget(descriptor: descriptor, routes: routes, route: route,
                          documentAttributes: documentAttributes, surface: surface,
                          dynamicResources: dynamicResources)
        record(Claim(page: descriptor.id, crossWindow: window != nil && window !== target,
                     spare: true, milliseconds: Self.milliseconds(since: start)))
        scheduleBuild()
        return host
    }

    /// Releases a claimed host. Only an untouched host with its document may return to the spare
    /// slot; a discarded one (PageWebView+Discard.swift) has no document to park.
    public func release(_ host: PageWebView) {
        host.removeFromSuperview()
        guard claimed.removeValue(forKey: ObjectIdentifier(host)) != nil else {
            host.close()
            return
        }
        if !host.touched, !host.isDiscarded, spare == nil, allowsSpare, let content = target?.contentView {
            host.countsTouches = false
            park(host, in: content)
            spare = host
            spareReady = false
            // main-hop-allow: resetPooledPage is the parked page's main-actor async reset (its script runs in the page); the task only marks the spare ready after it
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

    /// Whether an open of Settings, History or Cloud shows in WebKit now, so a spare could serve it: the engine
    /// decision ``claim(_:routes:route:documentAttributes:options:surface:dynamicResources:window:focus:)`` takes,
    /// with no side effect (it arms no web-override watch). With Chromium as their engine a spare is a WebKit
    /// page no open takes.
    ///
    /// - Parameter hosting: The app's Chromium page maker (`WebUIHost.chromium`); nil for WebKit only.
    public func servesOpens(hosting: (any PageChromiumHosting)?) -> Bool {
        PageServedHosts.pooledDescriptors.contains { page in
            PageWebView.engineDecisionNow(for: page, options: options, hosting: hosting).engine == .webKit
        }
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
