import AppKit
import CmuxNextCompat
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
/// window-corner drag's commits were held 155 ms at p50 and over 1 s at p95 for a 17 ms deadline, and NIGHTLY's
/// divider drags released their expired fences about 520 ms late.)
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
        // A fence whose right its deadline already dropped (off the main thread) takes no page.
        if let open = current[key], open.right.isHeld {
            fence = open
        } else {
            guard let port = makePort(layer) else { return false }
            fence = CEFResizeFence(port: port)
            current[key] = fence
            CEFHostView.trackerStats.resizeFences += 1
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
            let right = fence.right
            fence.deadline = Task.detached(priority: .high) {
                // wakeup-allow: one-shot deadline of one resize turn (a frame or two), cancelled when every page reported
                do { try await clock.sleep(for: after) } catch { return }
                // Off the main thread: the main thread may be waiting for the commit this right holds.
                right.drop()
                await fence.expire()
            }
        }
        let done: @MainActor (Bool) -> Void = { [weak fence] presented in
            if presented { CEFHostView.trackerStats.resizeFencePresented += 1 } else { CEFHostView.trackerStats.resizeFenceMissed += 1 }
            guard let fence else { return }
            fence.outstanding -= 1
            if fence.outstanding <= 0, fence.sealed { fence.drop() }
        }
        // The port only while the right is held: a name dropped off the main thread may already name another port.
        let joined = fence.right.withPort { port in ask(port, done) } ?? false
        if joined {
            fence.outstanding += 1
            CEFHostView.trackerStats.resizeFenceJoined += 1
        }
        return joined
    }
}

/// This app's send right on one window fence's port, dropped once by whichever comes first: the main thread when every
/// page reported, or the fence's deadline, off the main thread (the main thread may be waiting for the commit it holds).
nonisolated final class CEFFenceRight: Sendable {
    private let port: Mutex<mach_port_t>

    init(port: mach_port_t) {
        self.port = Mutex(port)
    }

    /// Whether the right is still held.
    var isHeld: Bool { port.withLock { $0 != mach_port_t(MACH_PORT_NULL) } }

    /// Runs `body` with the port while the right is held, so no caller hands on a name the right no longer backs (a
    /// dropped name can come back for another port); nil once it is dropped. A drop from another thread waits for it.
    func withPort(_ body: (mach_port_t) -> Bool) -> Bool? {
        port.withLock { port in port == mach_port_t(MACH_PORT_NULL) ? nil : body(port) }
    }

    /// Drops the right; true the first time.
    @discardableResult
    func drop() -> Bool {
        port.withLock { port in
            guard port != mach_port_t(MACH_PORT_NULL) else { return false }
            mach_port_deallocate(mach_task_self_, port)
            port = mach_port_t(MACH_PORT_NULL)
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
    /// Set once the fence's bookkeeping ran (``drop()``); the right itself may have gone earlier, at the deadline.
    fileprivate var dropped = false
    fileprivate var deadline: Task<Void, Never>?

    fileprivate init(port: mach_port_t) {
        right = CEFFenceRight(port: port)
    }

    fileprivate func seal() {
        sealed = true
        if outstanding <= 0 { drop() }
    }

    /// The deadline came: the right goes (unless it went already, off the main thread) and an unreported page counts
    /// as expired.
    fileprivate func expire() {
        if outstanding > 0, !dropped { CEFHostView.trackerStats.resizeFencesExpired += 1 }
        drop()
    }

    fileprivate func drop() {
        guard !dropped else { return }
        dropped = true
        right.drop()
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
