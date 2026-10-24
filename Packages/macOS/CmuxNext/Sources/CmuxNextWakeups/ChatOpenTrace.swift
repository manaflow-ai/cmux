#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

/// DEBUG builds: one agent chat open, from the action to the chat's content on screen, stage by
/// stage, in either engine (`debug.chat_open_trace`; Leo 2026-10-22: "flickers the initial thing
/// ... then it just goes to black screen for a while").
///
/// Disarmed (every run but a trace run) a mark site costs one Bool read and does nothing else.
/// ``begin(launch:)`` arms one trace, the open id every mark of it shares; each mark keeps its
/// first time only. The first pane made after arming binds the trace (``bind(surface:)``): from
/// then until ``finish(timedOut:)``, or ``frameCap`` at the latest, every display frame samples
/// which surface that pane shows (its pane hold, its loading cover, the page before or after its
/// first contentful paint), and only a change is kept.
///
/// Times are milliseconds after `action` (after arming when no action ran: a launch trace).
@MainActor
public final class ChatOpenTrace {
    /// Armed from its first use when the app was asked to trace its launch
    /// (`CMUX_CHAT_OPEN_TRACE_LAUNCH=1` or `--chat-open-trace-launch`): the first pane a relaunch
    /// restores binds it, and its times run from the process start.
    public static let shared: ChatOpenTrace = {
        let trace = ChatOpenTrace()
        let process = ProcessInfo.processInfo
        if process.environment["CMUX_CHAT_OPEN_TRACE_LAUNCH"] == "1" || process.arguments.contains("--chat-open-trace-launch") {
            _ = trace.begin(launch: true)
        }
        return trace
    }()
    /// Finished traces kept for `get`.
    public static let capacity = 16
    /// The agent chat page's id (`PageDescriptor.agent`): only its marks are a chat open's.
    public static let agentPageID = "cmux.agent"
    /// The frame sampler stops by itself after this, whether or not the trace finished.
    public static let frameCap: TimeInterval = 15

    public enum Mark: Int, CaseIterable, Sendable {
        case action, paneMade, holdBegin, chromiumStart, cefWindowCreate, cefWindowCreated, browserCreated,
             setupDone, navigationStart, committed, firstContentfulPaint, pagePainted, panePainted,
             loadingLeave, loadingLeft, holdEnd

        /// The mark's name in `debug.chat_open_trace` results.
        public var name: String {
            switch self {
            case .action: "action"
            case .paneMade: "pane_made"
            case .holdBegin: "hold_begin"
            case .chromiumStart: "chromium_start"
            case .cefWindowCreate: "cef_window_create"
            case .cefWindowCreated: "cef_window_created"
            case .browserCreated: "browser_created"
            case .setupDone: "setup_done"
            case .navigationStart: "navigation_start"
            case .committed: "committed"
            case .firstContentfulPaint: "first_contentful_paint"
            case .pagePainted: "page_painted"
            case .panePainted: "pane_painted"
            case .loadingLeave: "loading_leave"
            case .loadingLeft: "loading_left"
            case .holdEnd: "hold_end"
            }
        }
    }

    /// What the bound pane shows in one frame.
    public enum Surface: String, Sendable {
        /// A pane hold keeps the outgoing content; the chat is not shown yet.
        case held
        /// The loading cover: the page background with no content (dark theme: near black).
        case cover
        /// The pane's last frame of the chat (a relaunch's launch image).
        case image
        /// The loading cover fading out over the page.
        case coverLeaving = "cover_leaving"
        /// The page shows but has not painted content (see-through: whatever is under it).
        case pageEmpty = "page_empty"
        /// The page shows its content.
        case page
        /// The pane left its window.
        case gone

        /// Nothing of the chat and nothing kept: what reads as a black or empty pane.
        public var isEmpty: Bool { self == .cover || self == .pageEmpty }
    }

    /// One trace.
    public struct Record: Sendable {
        public let id: Int
        public let launch: Bool
        public internal(set) var timedOut = false
        /// The engine the bound pane's chat showed in (`cef`, `webkit:…`).
        public internal(set) var engine: String?
        let armedAt: TimeInterval
        /// Wall-clock seconds at arming, to line a trace up with a screen recording.
        public let armedWall = Date().timeIntervalSince1970
        var marks = [TimeInterval?](repeating: nil, count: Mark.allCases.count)
        /// Each change of the bound pane's surface: uptime, surface.
        var frames: [(TimeInterval, Surface)] = []
        public internal(set) var frameCount = 0
        /// When sampling stopped (finish or ``frameCap``): an empty run still on screen then ends here.
        var endedAt: TimeInterval?

        var origin: TimeInterval { marks[Mark.action.rawValue] ?? armedAt }

        /// Milliseconds from the origin to `mark`; nil when it never ran.
        public func milliseconds(_ mark: Mark) -> Double? {
            marks[mark.rawValue].map { ($0 - origin) * 1_000 }
        }

        /// The surface changes, in milliseconds from the origin.
        public var surfaces: [(ms: Double, surface: Surface)] {
            frames.map { (($0.0 - origin) * 1_000, $0.1) }
        }

        /// Milliseconds from the origin to the first frame of chat content.
        public var firstContentMilliseconds: Double? {
            surfaces.first { $0.surface == .page || $0.surface == .coverLeaving }?.ms
        }

        /// The longest run of empty frames (``Surface/isEmpty``), in milliseconds.
        public var longestEmptyMilliseconds: Double {
            var longest = 0.0
            var start: Double?
            for (ms, surface) in surfaces {
                if surface.isEmpty {
                    if start == nil { start = ms }
                } else if let begun = start {
                    longest = max(longest, ms - begun)
                    start = nil
                }
            }
            if let begun = start, let endedAt { longest = max(longest, (endedAt - origin) * 1_000 - begun) }
            return longest
        }
    }

    public private(set) var isArmed = false
    /// The traced chat's page: the first agent page that marks after arming. Page marks of any
    /// other page are not this open's.
    private var page: ObjectIdentifier?
    /// The Chromium pane key of the traced chat's page (`ChromiumPageHost`), for the marks of the
    /// Chromium window and its first contentful paint.
    public var chromiumPane: String?
    /// The traced chat's pane (``bind(view:page:surface:engine:)``). Pane marks of any other view are
    /// not this open's.
    private weak var view: NSView?
    private var current: Record?
    private var finished: [Record] = []
    private var nextID = 1
    private var surface: (() -> Surface)?
    private var engine: (() -> String)?
    private var sampler: FrameClient?
    private var waiter: CheckedContinuation<Void, Never>?

    /// Arms a trace; false while one runs. A launch trace has no action: its origin is the arming.
    public func begin(launch: Bool = false) -> Bool {
        guard current == nil else { return false }
        current = Record(id: nextID, launch: launch, armedAt: launch ? Self.processStart() : Self.now())
        nextID += 1
        surface = nil
        engine = nil
        page = nil
        view = nil
        chromiumPane = nil
        makingTracedPage = false
        isArmed = true
        return true
    }

    /// Records `mark` for the running trace, at its first time only.
    public func mark(_ mark: Mark) {
        guard isArmed, current?.marks[mark.rawValue] == nil else { return }
        current?.marks[mark.rawValue] = Self.now()
        if mark == .loadingLeft || mark == .holdEnd { resumeIfShown() }
    }

    /// Records `mark` of `page` (an agent page): the first one to mark binds the trace.
    public func mark(_ mark: Mark, page: AnyObject) {
        guard isArmed else { return }
        let id = ObjectIdentifier(page)
        if self.page == nil { self.page = id }
        if self.page == id { self.mark(mark) }
    }

    /// Records `mark` of `view`: the agent pane, a view in it (its loading cover, while still in
    /// it), or a view that contains it (the pane hold's incoming view). Once a pane is bound, any
    /// other view's marks are not this open's; before the bind (a hold begins before the pane shows
    /// its loading state) the first one counts.
    public func mark(_ mark: Mark, view: NSView) {
        guard isArmed else { return }
        if let bound = self.view, !view.isDescendant(of: bound), !bound.isDescendant(of: view) { return }
        self.mark(mark)
    }

    /// Set by the traced chat's own page right before it asks for its Chromium page
    /// (`PageWebView.startChromium`); the Chromium host takes it in that same main-actor turn
    /// (``takeMakingTracedPage()``), so it binds that page's pane (``chromiumPane``) and no other's.
    public var makingTracedPage = false

    /// Whether the Chromium page being made is the traced chat's; clears the flag.
    public func takeMakingTracedPage() -> Bool {
        defer { makingTracedPage = false }
        return isArmed && makingTracedPage
    }

    /// Whether `page` is the traced chat's page.
    public func isTraced(page: AnyObject) -> Bool { isArmed && self.page == ObjectIdentifier(page) }

    /// Records `mark` of the Chromium pane `pane`, when it is the traced chat's.
    public func mark(_ mark: Mark, chromiumPane pane: String?) {
        guard isArmed, let pane, pane == chromiumPane else { return }
        self.mark(mark)
    }

    /// Whether the running trace recorded `mark`.
    public func has(_ mark: Mark) -> Bool { current?.marks[mark.rawValue] != nil }

    /// The pane of the traced page (the first pane made after arming, without a page) binds the trace: `surface` is sampled every frame of
    /// `view`'s display and `engine` read at the end. Later panes are not this open's.
    @discardableResult
    public func bind(view: NSView, page: AnyObject?, surface: @escaping () -> Surface, engine: @escaping () -> String) -> Bool {
        guard isArmed, self.surface == nil else { return false }
        if let page {
            let id = ObjectIdentifier(page)
            if self.page == nil { self.page = id }
            guard self.page == id else { return false }
        }
        self.surface = surface
        self.engine = engine
        self.view = view
        mark(.paneMade)
        let client = FrameClient(owner: "chatOpenTrace", isAnimation: false, scheduler: { [weak view] in
            view.map(FrameScheduler.forView) ?? .app
        }) { [weak self] _ in self?.sample() ?? false }
        sampler = client
        client.activate()
        sample()
        return true
    }

    /// Whether the bound pane's chat shows: its loading cover left and no hold keeps it hidden.
    public var chatShown: Bool {
        guard let record = current, record.marks[Mark.loadingLeft.rawValue] != nil else { return false }
        return surface?() != .held
    }

    /// Waits until the chat shows or `timeout` passes; true when it showed.
    public func waitUntilShown(timeout: Duration) async -> Bool {
        if chatShown { return true }
        let deadline = DemandTimer(owner: "chatOpenTrace.wait")
        deadline.schedule(after: timeout) { @MainActor [weak self] in self?.resume() }
        await withCheckedContinuation { waiter = $0 }
        deadline.cancel()
        return chatShown
    }

    /// Lets `duration` of frames be sampled before the caller finishes the trace.
    public func settle(for duration: Duration) async {
        let timer = DemandTimer(owner: "chatOpenTrace.settle")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            timer.schedule(after: duration) { @MainActor in done.resume() }
        }
        withExtendedLifetime(timer) {}
    }

    /// Disarms the trace and keeps its record; nil when none ran.
    public func finish(timedOut: Bool) -> Record? {
        sample()
        isArmed = false
        sampler?.deactivate()
        sampler = nil
        guard var record = current else { return nil }
        record.timedOut = timedOut
        record.endedAt = min(Self.now(), record.armedAt + Self.frameCap)
        record.engine = engine?()
        current = nil
        surface = nil
        engine = nil
        finished.append(record)
        if finished.count > Self.capacity { finished.removeFirst(finished.count - Self.capacity) }
        resume()
        return record
    }

    /// The last `count` finished traces, oldest first, then the running one.
    public func recent(_ count: Int) -> [Record] {
        Array((finished + (current.map { [$0] } ?? [])).suffix(max(count, 0)))
    }

    @discardableResult
    private func sample() -> Bool {
        guard isArmed, var record = current, let surface else { return false }
        let now = Self.now()
        guard now - record.armedAt < Self.frameCap else { return false }
        let shown = surface()
        record.frameCount += 1
        if record.frames.last?.1 != shown { record.frames.append((now, shown)) }
        current = record
        return true
    }

    private func resumeIfShown() {
        if chatShown { resume() }
    }

    private func resume() {
        let waiting = waiter
        waiter = nil
        waiting?.resume()
    }

    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The process's start on the ``now()`` clock (now when the kernel does not say).
    static func processStart() -> TimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return now() }
        let started = info.kp_proc.p_starttime
        let startWall = TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000
        return now() - max(Date().timeIntervalSince1970 - startWall, 0)
    }
}

#endif
