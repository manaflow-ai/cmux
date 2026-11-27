import AppKit
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
            // After this turn no page joins; a fence nobody joined goes at once.
            CEFLayerHosting.atEndOfTurn { [weak self] in
                if self?.current[key] === fence { self?.current[key] = nil }
                fence.seal()
            }
            // This app's own deadline: the commit never waits longer than the GPU's deadline and one refresh.
            let clock = clock
            let after = Duration.milliseconds(Int64(timeoutMs)) + .microseconds(Int64(max(refreshMs, 1) * 1_000))
            // The deadline runs off the main actor and holds the fence's send right (``CEFFenceRight``) until it or
            // `drop()` frees it: once the turn ended nothing else does, and a right freed with nobody dropping it would hold
            // the window's commits for good. Off the main actor, because the render server holds every later commit of
            // the window while the fence is open: a main thread busy in one of those commits (or anything else) cannot
            // run a main-actor deadline, so the fence stayed open past its deadline for as long as the main thread was
            // busy. Nightly c6ff12463, s9-browser-w30 divider drag: both fences of each round expired, and those rounds
            // showed 3 or 4 frames in about 900 ms (frame p50 242 ms, max 928 ms).
            let right = fence.right
            fence.deadline = Task.detached {
                // wakeup-allow: one-shot deadline of one resize turn (a frame or two), cancelled when every page reported
                do { try await clock.sleep(for: after) } catch { return }
                guard right.drop() else { return }
                Task { @MainActor in CEFHostView.trackerStats.resizeFencesExpired += 1 }
            }
        }
        let joined = ask(fence.right.port) { [weak fence] presented in
            if presented { CEFHostView.trackerStats.resizeFencePresented += 1 } else { CEFHostView.trackerStats.resizeFenceMissed += 1 }
            guard let fence else { return }
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
    fileprivate let right: CEFFenceRight
    fileprivate var outstanding = 0
    fileprivate var sealed = false
    fileprivate var deadline: Task<Void, Never>?

    fileprivate init(port: mach_port_t) {
        right = CEFFenceRight(port: port)
    }

    fileprivate func seal() {
        sealed = true
        if outstanding <= 0 { drop() }
    }

    fileprivate func drop() {
        guard right.drop() else { return }
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

/// The app's send right on one fence, freed once by whichever comes first: every page reported (main actor) or the
/// fence's deadline (off the main actor, ``CEFResizeFences/join(window:layer:timeoutMs:refreshMs:ask:)``).
nonisolated final class CEFFenceRight: @unchecked Sendable {
    private let lock = NSLock()
    private var name: mach_port_t

    init(port: mach_port_t) { name = port }

    /// The port while the right is held; `MACH_PORT_NULL` once freed.
    var port: mach_port_t { lock.withLock { name } }

    /// Frees the right; false when it was freed already.
    func drop() -> Bool {
        let taken: mach_port_t = lock.withLock {
            defer { name = mach_port_t(MACH_PORT_NULL) }
            return name
        }
        guard taken != mach_port_t(MACH_PORT_NULL) else { return false }
        mach_port_deallocate(mach_task_self_, taken)
        return true
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
