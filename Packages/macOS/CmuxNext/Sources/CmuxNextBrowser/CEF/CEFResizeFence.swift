import AppKit
import CmuxNextCompat
import CmuxNextDesign
import QuartzCore

/// Window frame sync (fork API 32, `cmux_browser_resize_fence`; plans/cmux-next/cef-layer-hosting-DESIGN.md, FRAME OWNER
/// S5): in the turn that resizes hosted pages, the window's Core Animation commit is fenced (`-[CAContext
/// createFencePort]`) and each resized page's GPU process sets that fence on its first frame at the new size. The render
/// server then shows the pane's commit and the page's frame together. Nothing on the main thread waits: the render server
/// holds the commit, and this app drops its own send right when every page reported (`done`) or at its own deadline.
///
/// The main thread can still wait for a fenced commit: the next commit's backing-store update synchronizes with the
/// render server (`CABackingStoreSynchronize`). So nothing that needs the main thread releases a fence: the deadline
/// drops the right on the cooperative pool (``CEFFenceRight``), and only the fence's bookkeeping waits for the main
/// actor. (A deadline on the main actor waited for the very thread it frees: on the page-sync bench, 2026-11-26, a
/// window-corner drag's commits were held 155 ms at p50 and over 1 s at p95 for a 17 ms deadline.)
///
/// One fence per window per run-loop turn; every hosted page resized in that turn joins it. The process's one set of
/// open fences is ``CEFRuntime/resizeFences``; each ``CEFLayerHosting`` is handed it.
///
/// How a live drag uses its fences is ``CEFFenceMode`` (a bench knob while the page-sync arms are measured).
@MainActor
final class CEFResizeFences {
    /// Asks the fork to take `port` for one page; true when it did (its `done` then comes once, on the main thread).
    typealias Join = (_ port: mach_port_t, _ done: @escaping @MainActor (_ presented: Bool) -> Void) -> Bool

    /// After Core Animation's commit (2,000,000) and before the resize step log's own (2,000,100): ``CEFFenceMode/commit``
    /// hands a fence to its pages' GPUs here.
    nonisolated static let afterCommitOrder: CFIndex = 2_000_050

    /// This turn's fence of each window.
    private var current: [ObjectIdentifier: CEFResizeFence] = [:]
    /// How long each window's in-tree page resizes wait, when the adaptive pace is on (``CEFFencePace/isOn``).
    let pace = CEFFencePace()
    private let clock: any Clock<Duration>
    private let makePort: @MainActor (CALayer) -> mach_port_t?
    /// How a live drag uses the fences (``CEFFenceMode/current`` by default).
    let mode: CEFFenceMode
    /// Which resized page views may join a window's fence (``CEFFenceMembers/current`` by default).
    let members: CEFFenceMembers
    /// ``CEFFenceMode/commit``: the fences whose window has not committed yet, and the observer after every commit that
    /// hands them to their pages (added at launch, so a fence opened in the display cycle's own callout is handed after
    /// that same pass's commit: an observer added during a stage misses that stage).
    private var awaitingCommit: [CEFResizeFence] = []
    private var afterCommit: MainRunLoopObserver?

    /// - Parameters:
    ///   - clock: runs this app's deadline of each fence.
    ///   - makePort: the fence of the window of a layer (`-[CAContext createFencePort]` by default; tests pass a port
    ///     of their own).
    ///   - mode: how a live drag uses the fences (``CEFFenceMode/current`` by default).
    ///   - members: which resized page views may join (``CEFFenceMembers/current`` by default).
    init(clock: any Clock<Duration> = ContinuousClock(),
         makePort: @escaping @MainActor (CALayer) -> mach_port_t? = { CEFResizeFence.createFencePort(layer: $0) },
         mode: CEFFenceMode = .current, members: CEFFenceMembers = .current) {
        self.clock = clock
        self.makePort = makePort
        self.mode = mode
        self.members = members
        if mode == .commit {
            afterCommit = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: Self.afterCommitOrder,
                                              drawsNothingAfterCommit: true) { [weak self] _ in self?.windowsCommitted() }
        }
    }

    /// Whether something of `view` shows in `window` (``CEFFenceMembers/shown``). Red stub: every view shows.
    static func shows(_ view: NSView, in window: NSWindow) -> Bool { true }

    /// ``CEFFenceMode/commit``: the windows' commits of this pass went; their fences go to their pages and their
    /// deadlines start.
    private func windowsCommitted() {
        guard !awaitingCommit.isEmpty else { return }
        let fences = awaitingCommit
        awaitingCommit = []
        let clock = clock
        for fence in fences {
            fence.committed { Self.startDeadline(fence, clock: clock, after: fence.after) }
        }
    }

    /// Joins one page resized in this turn to `window`'s fence for this turn (made on first use).
    /// - Parameters:
    ///   - layer: any layer of the window's tree (its context is the window's).
    ///   - timeoutMs: the GPU's deadline for the page's frame; this app's own comes one refresh later (both from the
    ///     window's commit with ``CEFFenceMode/commit``).
    /// - Returns: Whether the page joined (with ``CEFFenceMode/commit``: whether it was taken in to join after the
    ///   commit).
    @discardableResult
    func join(window: NSWindow, layer: CALayer, timeoutMs: Int32, refreshMs: Double, ask: @escaping Join) -> Bool {
        let key = ObjectIdentifier(window)
        let fence: CEFResizeFence
        // A fence whose right its deadline already dropped (off the main thread) takes no page.
        if let open = current[key], open.right.isHeld {
            fence = open
        } else {
            guard let port = makePort(layer) else { return false }
            fence = CEFResizeFence(port: port)
            current[key] = fence
            CEFHostView.trackerStats.resizeFences += 1
            // The resize step this fence holds the commit of (`ResizeStepTimes`, while its log streams).
            fence.step = ResizeStepTimes.openStep
            if fence.step != nil {
                fence.opened = DispatchTime.now().uptimeNanoseconds
                ResizeStepTimes.note("fence_open", ms: Double(timeoutMs), step: fence.step)
            }
            // After this turn no page joins; a fence nobody joined goes at once.
            CEFLayerHosting.atEndOfTurn { [weak self] in
                if self?.current[key] === fence { self?.current[key] = nil }
                fence.seal()
            }
            // This app's own deadline: the commit never waits longer than the GPU's deadline and one refresh.
            let clock = clock
            let after = Duration.milliseconds(Int64(timeoutMs)) + .microseconds(Int64(max(refreshMs, 1) * 1_000))
            if mode == .commit {
                // The pages' GPUs get the fence after the window's commit, and both deadlines run from there.
                // ``awaitingCommit`` holds the fence (and so its port) until then.
                fence.awaitsCommit = true
                fence.after = after
                awaitingCommit.append(fence)
            } else {
                Self.startDeadline(fence, clock: clock, after: after)
            }
        }
        // The step and open time of the fence, for a page that reports after the fence itself is gone.
        let (step, opened) = (fence.step, fence.opened)
        let done: @MainActor (Bool) -> Void = { [weak fence] presented in
            if presented { CEFHostView.trackerStats.resizeFencePresented += 1 } else { CEFHostView.trackerStats.resizeFenceMissed += 1 }
            let outcome = presented ? " presented=1" : " presented=0"
            guard let fence else {
                // The fence went before this page reported (its deadline, then its bookkeeping): the step log still
                // counts the page, `late=1` (its time since the fence opened, when the main thread heard of it).
                CEFResizeFence.note(step: step, opened: opened, "fence_page", outcome + " late=1")
                return
            }
            fence.note("fence_page", outcome + (fence.dropped ? " late=1" : ""))
            fence.outstanding -= 1
            if fence.outstanding <= 0, fence.sealed { fence.drop() }
        }
        if fence.awaitsCommit {
            // ``CEFFenceMode/commit``: the page's GPU gets the fence after the window's commit.
            fence.pending.append((ask, done))
            return true
        }
        return fence.hand(ask, done)
    }

    /// Starts `fence`'s deadline. The task holds the fence (and so its port) until the deadline or `drop()`: once the
    /// turn ended nothing else does, and a fence freed with its send right would hold the window's commits for good.
    private static func startDeadline(_ fence: CEFResizeFence, clock: any Clock<Duration>, after: Duration) {
        #if CMUX_BENCH_HOOKS
        if benchDeadlineOnMain {
            fence.deadline = Task {
                // wakeup-allow: one-shot deadline of one resize turn (a frame or two), cancelled when every page reported
                do { try await clock.sleep(for: after) } catch { return }
                fence.expire()
            }
            return
        }
        #endif
        let right = fence.right
        fence.deadline = Task.detached(priority: .high) {
            // wakeup-allow: one-shot deadline of one resize turn (a frame or two), cancelled when every page reported
            do { try await clock.sleep(for: after) } catch { return }
            // Off the main thread: the main thread may be waiting for the commit this right holds.
            right.drop()
            await fence.expire()
        }
    }

    #if CMUX_BENCH_HOOKS
    /// Bench builds only (never shipped): `CMUX_NEXT_CEF_FENCE_DEADLINE=main` puts the deadline back on the main actor,
    /// the shipped behaviour before lever 4a, as the page-sync arms' a0 control.
    nonisolated static let benchDeadlineOnMain = ProcessInfo.processInfo.environment["CMUX_NEXT_CEF_FENCE_DEADLINE"] == "main"
    #endif
}

/// How a live drag's resizes use the window's fences: `CMUX_NEXT_CEF_FENCE_MODE` (a `CMUX_NEXT_` knob, kept by the
/// launch strip), a bench arm while the page-sync bench measures them (2026-11-26). In a continuous drag a page's GPU
/// keeps one fence, takes only a frame at exactly the fence's size, and waits 9 ms from its own receipt, which comes in
/// the window's layout, before its commit: the renderer's frame at a step's size (the resize message, a begin frame,
/// the draw, the display's) comes after that, or after the next step's fence replaced it, so the commit is held for no
/// page.
/// Which resized page views join a window's fence: `CMUX_NEXT_CEF_FENCE_MEMBERS` (a `CMUX_NEXT_` knob, kept by the launch
/// strip), a bench arm while the page-sync bench measures it (2026-11-26). Every window-corner step waited on one page
/// nobody sees: the next Cmd-N's reserved workspace, mounted alpha 0 and 100 000 pt off the content with its autoresizing
/// on (`addPrewarmedSubview`), takes the window's size each step and joins, and a hidden page seldom presents, so the
/// fence expires (page-sync fd1 seed 1: 114 of 160 corner fences waited on 5 pages for the 4 shown). The osr pages got
/// the same rule in 17dd9461: a page nobody sees keeps its size and joins no window fence.
enum CEFFenceMembers: String, Sendable {
    /// Every resized page view in the window joins (the shipped behaviour).
    case all
    /// Only a page view something of which shows in its window joins (``CEFResizeFences/shows(_:in:)``).
    case shown

    /// The launch's rule (`all` unless `CMUX_NEXT_CEF_FENCE_MEMBERS` names another).
    nonisolated static let current = CEFFenceMembers(rawValue: ProcessInfo.processInfo.environment["CMUX_NEXT_CEF_FENCE_MEMBERS"] ?? "") ?? .all
}

enum CEFFenceMode: String, Sendable {
    /// Every resized page joins its turn's fence (the default).
    case each
    /// No fence while a person's drag moves (a window's live resize, a pane drag); one on the final size when it ends.
    /// NIGHTLY's layer-hosted pages hold no window resize at all.
    case release
    /// The pages' GPUs get the fence only after the window's commit, with two refreshes for a frame at the new size;
    /// this app's deadline (one refresh later) runs from the commit too.
    case commit

    /// The launch's mode (`each` unless `CMUX_NEXT_CEF_FENCE_MODE` names another).
    nonisolated static let current = CEFFenceMode(rawValue: ProcessInfo.processInfo.environment["CMUX_NEXT_CEF_FENCE_MODE"] ?? "") ?? .each
}

/// This app's send right on one window fence's port, dropped once by whichever comes first: the main thread when every
/// page reported, or the fence's deadline, off the main thread (the main thread may be waiting for the commit it holds).
nonisolated final class CEFFenceRight: Sendable {
    private nonisolated struct State {
        var port: mach_port_t
        /// When the right was dropped (uptime ns); 0 while it is held.
        var droppedAt: UInt64 = 0
    }

    private let state: Mutex<State>

    init(port: mach_port_t) {
        state = Mutex(State(port: port))
    }

    /// Whether the right is still held.
    var isHeld: Bool { state.withLock { $0.port != mach_port_t(MACH_PORT_NULL) } }
    /// When the right was dropped (uptime ns), nil while it is held.
    var droppedAt: UInt64? { state.withLock { $0.droppedAt == 0 ? nil : $0.droppedAt } }

    /// Runs `body` with the port while the right is held, so no caller hands on a name the right no longer backs (a
    /// dropped name can come back for another port); nil once it is dropped. A drop from another thread waits for it.
    func withPort(_ body: (mach_port_t) -> Bool) -> Bool? {
        state.withLock { state in
            state.port == mach_port_t(MACH_PORT_NULL) ? nil : body(state.port)
        }
    }

    /// Drops the right; true the first time.
    @discardableResult
    func drop() -> Bool {
        state.withLock { state in
            guard state.port != mach_port_t(MACH_PORT_NULL) else { return false }
            mach_port_deallocate(mach_task_self_, state.port)
            state.port = mach_port_t(MACH_PORT_NULL)
            state.droppedAt = DispatchTime.now().uptimeNanoseconds
            return true
        }
    }
}

/// One window's fence of one turn (``CEFResizeFences``).
@MainActor
final class CEFResizeFence {
    fileprivate let right: CEFFenceRight
    fileprivate var outstanding = 0
    fileprivate var sealed = false
    /// Set once the fence's bookkeeping ran (``drop(expired:)``); the right itself may have gone earlier.
    fileprivate var dropped = false
    fileprivate var deadline: Task<Void, Never>?
    /// The resize step whose commit this fence holds, and when it opened (uptime ns), while the step log streams.
    fileprivate var step: UInt64?
    fileprivate var opened: UInt64 = 0
    /// ``CEFFenceMode/commit``: the window has not committed yet; the pages waiting for the fence until it does, and
    /// this app's deadline from then.
    fileprivate var awaitsCommit = false
    fileprivate var pending: [(CEFResizeFences.Join, @MainActor (Bool) -> Void)] = []
    fileprivate var after: Duration = .zero

    fileprivate init(port: mach_port_t) {
        right = CEFFenceRight(port: port)
    }

    fileprivate func seal() {
        sealed = true
        if outstanding <= 0, pending.isEmpty, !awaitsCommit { drop() }
    }

    /// Hands the fence's port to one page (only while the right is held: a name dropped off the main thread may already
    /// name another port); true when the page took it.
    fileprivate func hand(_ ask: CEFResizeFences.Join, _ done: @escaping @MainActor (Bool) -> Void) -> Bool {
        let joined = right.withPort { port in ask(port, done) } ?? false
        if joined {
            outstanding += 1
            CEFHostView.trackerStats.resizeFenceJoined += 1
        }
        return joined
    }

    /// ``CEFFenceMode/commit``: the window's commit went; the waiting pages get the fence and the deadline starts.
    fileprivate func committed(startDeadline: () -> Void) {
        awaitsCommit = false
        guard !dropped else { return }
        let asks = pending
        pending = []
        note("fence_sent", " pages=\(asks.count)")
        for (ask, done) in asks { _ = hand(ask, done) }
        startDeadline()
        if sealed, outstanding <= 0 { drop() }
    }

    /// A fact of this fence for its step's log (`fence_page`, `fence_released`): the time since it opened, to `at`
    /// (uptime ns; now by default).
    fileprivate func note(_ phase: String, _ detail: String, at: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        Self.note(step: step, opened: opened, phase, detail, at: at)
    }

    /// A fence's fact for the step log, given the fence's step and open time (nil step: the log was not streaming).
    fileprivate static func note(step: UInt64?, opened: UInt64, _ phase: String, _ detail: String,
                                 at: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard let step else { return }
        ResizeStepTimes.note(phase, ms: Double(at &- opened) / 1_000_000, step: step, detail: detail)
    }

    /// The deadline came: the right goes (unless it went already, off the main thread) and an unreported page counts
    /// as expired.
    fileprivate func expire() {
        if outstanding > 0 { CEFHostView.trackerStats.resizeFencesExpired += 1 }
        drop(expired: outstanding > 0)
    }

    fileprivate func drop(expired: Bool = false) {
        guard !dropped else { return }
        dropped = true
        let now = DispatchTime.now().uptimeNanoseconds
        let here = right.drop()
        let at = right.droppedAt ?? now
        // off_main: the deadline dropped the right off the main thread, `main_ms` before the main thread got here.
        let offMain = here ? "" : String(format: " off_main=1 main_ms=%.3f", Double(now &- at) / 1_000_000)
        note("fence_released", (expired ? " expired=1 outstanding=\(outstanding)" : " expired=0") + offMain, at: at)
        outstanding = 0
        deadline?.cancel()
        deadline = nil
        awaitsCommit = false
        pending = []
    }

    /// `-[CAContext createFencePort]` on the context of `layer`'s tree (QuartzCore SPI, as Chromium's
    /// `CALayerTreeCoordinator` and WebKit use it): the render server holds this transaction's commit of that context,
    /// and the ones after it, until every send right of the port is gone.
    static func createFencePort(layer: CALayer) -> mach_port_t? {
        let contextGetter = #selector(CEFFenceSPI.cmuxContext)
        let create = #selector(CEFFenceSPI.cmuxCreateFencePort)
        guard layer.responds(to: contextGetter),
              let context = layer.perform(contextGetter)?.takeUnretainedValue() as? NSObject,
              context.responds(to: create) else { return nil }
        typealias CreateFencePort = @convention(c) (NSObject, Selector) -> mach_port_t
        let call = unsafeBitCast(context.method(for: create), to: CreateFencePort.self)
        let port = call(context, create)
        return port == mach_port_t(MACH_PORT_NULL) ? nil : port
    }
}

/// The two QuartzCore SPI selectors ``CEFResizeFence/createFencePort(layer:)`` sends, named at compile time: no object
/// conforms, and each send is behind `responds(to:)`, so an OS without them gets no fence instead of an exception.
@objc private protocol CEFFenceSPI {
    /// `-[CALayer context]`: the `CAContext` of the layer's tree.
    @objc(context) func cmuxContext() -> NSObject?
    /// `-[CAContext createFencePort]`.
    @objc(createFencePort) func cmuxCreateFencePort() -> mach_port_t
}

/// The fork's `done` for a joined page: `context` is a retained ``CEFResizeFenceDone``.
nonisolated let cefResizeFenceDone: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { context, presented in
    guard let context else { return }
    let box = Unmanaged<CEFResizeFenceDone>.fromOpaque(context).takeRetainedValue()
    let shown = presented != 0
    // The fork calls on Chromium's UI thread (the main thread); the main run loop runs the block in this same pass.
    CEFLayerHosting.atEndOfTurn { box.run(shown) }
}

/// One page's `done`, kept alive across the C call (``cefResizeFenceDone``).
@MainActor
final class CEFResizeFenceDone {
    private let block: @MainActor (Bool) -> Void
    nonisolated init(_ block: @escaping @MainActor (Bool) -> Void) { self.block = block }
    func run(_ presented: Bool) { block(presented) }
}
