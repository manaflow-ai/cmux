import AppKit
import CmuxNextDesign
import QuartzCore

/// Window frame sync (fork API 32, `cmux_browser_resize_fence`; plans/cmux-next/cef-layer-hosting-DESIGN.md, FRAME OWNER
/// S5): in the turn that resizes hosted pages, the window's Core Animation commit is fenced (`-[CAContext
/// createFencePort]`) and each resized page's GPU process sets that fence on its first frame at the new size. The render
/// server then shows the pane's commit and the page's frame together. Nothing on the main thread waits: the render server
/// holds the commit, and this app drops its own send right when every page reported (`done`) or at its own deadline.
///
/// One fence per window per run-loop turn; every hosted page resized in that turn joins it. The process's one set of
/// open fences is ``CEFRuntime/resizeFences``; each ``CEFLayerHosting`` is handed it.
@MainActor
final class CEFResizeFences {
    /// Asks the fork to take `port` for one page; true when it did (its `done` then comes once, on the main thread).
    typealias Join = (_ port: mach_port_t, _ done: @escaping @MainActor (_ presented: Bool) -> Void) -> Bool

    /// This turn's fence of each window.
    private var current: [ObjectIdentifier: CEFResizeFence] = [:]
    private let clock: any Clock<Duration>
    private let makePort: @MainActor (CALayer) -> mach_port_t?

    /// - Parameters:
    ///   - clock: runs this app's deadline of each fence.
    ///   - makePort: the fence of the window of a layer (`-[CAContext createFencePort]` by default; tests pass a port
    ///     of their own).
    init(clock: any Clock<Duration> = ContinuousClock(),
         makePort: @escaping @MainActor (CALayer) -> mach_port_t? = { CEFResizeFence.createFencePort(layer: $0) }) {
        self.clock = clock
        self.makePort = makePort
    }

    /// Joins one page resized in this turn to `window`'s fence for this turn (made on first use).
    /// - Parameters:
    ///   - layer: any layer of the window's tree (its context is the window's).
    ///   - timeoutMs: the GPU's deadline for the page's frame; this app's own comes one refresh later.
    /// - Returns: Whether the page joined.
    @discardableResult
    func join(window: NSWindow, layer: CALayer, timeoutMs: Int32, refreshMs: Double, ask: Join) -> Bool {
        let key = ObjectIdentifier(window)
        let fence: CEFResizeFence
        if let open = current[key] {
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
            // The task holds the fence (and so its port) until the deadline or `drop()`: once the turn ended nothing
            // else does, and a fence freed with its send right would hold the window's commits for good.
            fence.deadline = Task {
                // wakeup-allow: one-shot deadline of one resize turn (a frame or two), cancelled when every page reported
                do { try await clock.sleep(for: after) } catch { return }
                if fence.outstanding > 0 { CEFHostView.trackerStats.resizeFencesExpired += 1 }
                fence.drop(expired: fence.outstanding > 0)
            }
        }
        let joined = ask(fence.port) { [weak fence] presented in
            if presented { CEFHostView.trackerStats.resizeFencePresented += 1 } else { CEFHostView.trackerStats.resizeFenceMissed += 1 }
            guard let fence else { return }
            fence.note("fence_page", presented ? " presented=1" : " presented=0")
            fence.outstanding -= 1
            if fence.outstanding <= 0, fence.sealed { fence.drop() }
        }
        if joined {
            fence.outstanding += 1
            CEFHostView.trackerStats.resizeFenceJoined += 1
        }
        return joined
    }
}

/// One window's fence of one turn (``CEFResizeFences``).
@MainActor
final class CEFResizeFence {
    fileprivate var port: mach_port_t
    fileprivate var outstanding = 0
    fileprivate var sealed = false
    fileprivate var deadline: Task<Void, Never>?
    /// The resize step whose commit this fence holds, and when it opened (uptime ns), while the step log streams.
    fileprivate var step: UInt64?
    fileprivate var opened: UInt64 = 0

    fileprivate init(port: mach_port_t) {
        self.port = port
    }

    fileprivate func seal() {
        sealed = true
        if outstanding <= 0 { drop() }
    }

    /// A fact of this fence for its step's log (`fence_page`, `fence_released`): the time since it opened.
    fileprivate func note(_ phase: String, _ detail: String) {
        guard let step else { return }
        ResizeStepTimes.note(phase, ms: Double(DispatchTime.now().uptimeNanoseconds &- opened) / 1_000_000, step: step, detail: detail)
    }

    fileprivate func drop(expired: Bool = false) {
        guard port != mach_port_t(MACH_PORT_NULL) else { return }
        note("fence_released", expired ? " expired=1 outstanding=\(outstanding)" : " expired=0")
        mach_port_deallocate(mach_task_self_, port)
        port = mach_port_t(MACH_PORT_NULL)
        outstanding = 0
        deadline?.cancel()
        deadline = nil
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
