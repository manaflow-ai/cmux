public import AppKit
public import CmuxNextSignposts
import CmuxNextTrace

/// One agent chat open, from the action to the chat's content on screen, stage by stage, in either engine.
///
/// Every build: each mark of an agent page or pane is a ``SignpostName/createTab`` instant (`kind=chat`) in the
/// trace ring, every time it happens, so a Release recording shows a chat open's stages inside its `create.tab`
/// pair (Chrome's `TRACE_EVENT_INSTANT` steps inside an async creation event, base/trace_event/trace_event.h).
/// The record's `arg0` is the chat kind's code with the stage's code (``Mark/traceCode``) in bits 8-15, its
/// `arg1` the trace id of the page or view that marked (an object's address, as `webui.open` keys its page), 0
/// for a Chromium pane's mark. With the `create` category off, a mark costs one relaxed load. Marks from code
/// every pane or Chromium window runs (``Mark/isFromSharedSite``) cannot tell a chat from other content: they
/// write their instant only for the chat of an armed trace, below.
///
/// DEBUG and bench builds also aggregate one open for `debug.chat_open_trace` (Leo 2026-10-22: "flickers the
/// initial thing ... then it just goes to black screen for a while"). Disarmed (every run but a trace run) that
/// part costs one Bool read. ``begin(launch:)`` arms one trace, the open id every mark of it shares; each mark
/// keeps its first time only. The first pane made after arming binds the trace (``bind(view:page:surface:engine:)``):
/// from then until ``finish(timedOut:)``, or ``frameCap`` at the latest, every display frame samples which
/// surface that pane shows (its pane hold, its loading cover, the page before or after its first contentful
/// paint), and only a change is kept. Times are milliseconds after `action` (after arming when no action ran:
/// a launch trace).
@MainActor
public final class ChatOpenTrace {
    /// Armed from its first use when the app was asked to trace its launch
    /// (`CMUX_CHAT_OPEN_TRACE_LAUNCH=1` or `--chat-open-trace-launch`, DEBUG and bench builds): the first pane a
    /// relaunch restores binds it, and its times run from the process start.
    public static let shared: ChatOpenTrace = {
        let trace = ChatOpenTrace()
        #if DEBUG || CMUX_BENCH_HOOKS
        let process = ProcessInfo.processInfo
        if process.environment["CMUX_CHAT_OPEN_TRACE_LAUNCH"] == "1" || process.arguments.contains("--chat-open-trace-launch") {
            _ = trace.begin(launch: true)
        }
        #endif
        return trace
    }()
    /// The agent chat page's id (`PageDescriptor.agent`): only its marks are a chat open's.
    public static let agentPageID = "cmux.agent"

    public enum Mark: Int, CaseIterable, Sendable {
        case action, paneMade, holdBegin, chromiumStart, cefWindowCreate, cefWindowCreated, browserCreated,
             setupDone, navigationStart, committed, firstContentfulPaint, pagePainted, panePainted,
             loadingLeave, loadingLeft, holdEnd

        /// The mark's name in `debug.chat_open_trace` results and its instant's `os_signpost` message.
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

        /// The stage's number in bits 8-15 of its ``SignpostName/createTab`` instant's `arg0`: its position + 1, so
        /// 0 stays the stand-in commit's. Fixed: a new mark goes at the end, so older rings decode.
        public var traceCode: UInt64 { UInt64(rawValue) + 1 }

        /// Whether its site is code every pane or every Chromium window runs (`PanePaintHold`, the CEF pane host),
        /// which cannot tell a chat from other content: its instant is written only for an armed trace's own chat.
        public var isFromSharedSite: Bool {
            switch self {
            case .holdBegin, .holdEnd, .cefWindowCreate, .cefWindowCreated, .firstContentfulPaint: true
            default: false
            }
        }
    }

    /// Where each mark's `create.tab` instant goes.
    private let signposter: Signposter

    /// - Parameter signposter: The `create` signposter (tests pass one on their own trace runtime).
    public init(signposter: Signposter = .create) {
        self.signposter = signposter
    }

    /// Records `mark` with no page or view: its instant, and the running trace's mark (DEBUG and bench builds).
    public func mark(_ mark: Mark) {
        emit(mark, subject: nil)
        #if DEBUG || CMUX_BENCH_HOOKS
        keep(mark)
        #endif
    }

    /// Records `mark` of `page`, an agent page (its caller checks the page's id, ``agentPageID``). In DEBUG and
    /// bench builds the first page to mark binds the running trace, and another page's marks are not its own.
    public func mark(_ mark: Mark, page: AnyObject) {
        emit(mark, subject: page)
        #if DEBUG || CMUX_BENCH_HOOKS
        guard isArmed else { return }
        let id = ObjectIdentifier(page)
        if self.page == nil { self.page = id }
        if self.page == id { keep(mark) }
        #endif
    }

    /// Records `mark` of `view`: the agent pane, a view in it (its loading cover, while still in it), or a view
    /// that contains it (the pane hold's incoming view). In DEBUG and bench builds, once a pane is bound, any other
    /// view's marks are not the running trace's; before the bind (a hold begins before the pane shows its loading
    /// state) the first one counts. A hold's mark (``Mark/isFromSharedSite``) writes its instant only then.
    public func mark(_ mark: Mark, view: NSView) {
        if !mark.isFromSharedSite { emit(mark, subject: view) }
        #if DEBUG || CMUX_BENCH_HOOKS
        guard isArmed else { return }
        if let bound = self.view, !view.isDescendant(of: bound), !bound.isDescendant(of: view) { return }
        if mark.isFromSharedSite, !has(mark) { emit(mark, subject: view) }
        keep(mark)
        #endif
    }

    /// The `create.tab` instant of `mark`: the chat kind and the stage in `arg0`, `subject`'s trace id in `arg1`.
    private func emit(_ mark: Mark, subject: AnyObject?) {
        let arg0 = CreateTabInterval.Kind.chat.traceCode | mark.traceCode << 8
        let arg1 = subject.map { UInt64(UInt(bitPattern: ObjectIdentifier($0))) } ?? 0
        signposter.event(.createTab, mark.name, arg0: arg0, arg1: arg1)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Finished traces kept for `get`.
    public static let capacity = 16
    /// The frame sampler stops by itself after this, whether or not the trace finished.
    public static let frameCap: TimeInterval = 15

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
        // wall-clock: a screen recording's frames carry wall-clock times; the trace's own times are uptime.
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

    /// Records `mark` of the Chromium pane `pane`, when it is the running trace's chat pane (``chromiumPane``): any
    /// Chromium window marks here, so only that match makes it a chat's stage and writes its instant.
    public func mark(_ mark: Mark, chromiumPane pane: String?) {
        guard isArmed, let pane, pane == chromiumPane else { return }
        if !has(mark) { emit(mark, subject: nil) }
        keep(mark)
    }

    /// Keeps `mark` for the running trace, at its first time only.
    private func keep(_ mark: Mark) {
        guard isArmed, current?.marks[mark.rawValue] == nil else { return }
        current?.marks[mark.rawValue] = Self.now()
        if mark == .loadingLeft || mark == .holdEnd { resumeIfShown() }
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
        mark(.paneMade, view: view)
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

    /// The process's start on the ``now()`` clock (now when the kernel does not say): the launch slices' one
    /// conversion of the kernel's wall-clock start onto the uptime clock (``LaunchClock/processStart()``).
    static func processStart(_ clock: LaunchClock = LaunchClock()) -> TimeInterval {
        guard let start = clock.processStart() else { return now() }
        return TimeInterval(start.uptimeNanos) / 1e9
    }
    #endif
}
