#if canImport(CCmuxNativeTranscriptFFI)
import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import QuartzCore

/// The native transcript's view (RFD 0121, read-only, behind `CMUX_NATIVE_TRANSCRIPT=1` or `debug.native_transcript`):
/// an NSView backed by a CAMetalLayer whose frames are drawn on the transcript's own render thread
/// (``NativeTranscriptThread``) by a CADisplayLink scheduled on that thread's run loop. Main only forwards size,
/// scale and wheel input as posted commands; it never waits on the render thread.
final class NativeTranscriptView: NSView {
    private let metalLayer = CAMetalLayer()
    private var thread: NativeTranscriptThread?
    /// The render thread's renderer, once it made one (nil before, or when the GPU or the scene could not be made).
    private(set) var renderer: NativeTranscriptRenderer?
    private var onReady: [(NativeTranscriptRenderer?) -> Void] = []
    private var ready = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.isOpaque = true
        metalLayer.allowsNextDrawableTimeout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // crash-allow: never decoded

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Starts the render thread once the view is in a window; `then` gets the renderer (nil when it failed).
    func start(then: @escaping (NativeTranscriptRenderer?) -> Void) {
        if ready { return then(renderer) }
        onReady.append(then)
        guard thread == nil, let window else { return }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        let target = NativeTranscriptLinkTarget()
        // concurrency-allow: a FrameClient ticks on main; this link runs on the transcript's own render thread (RFD 0121).
        // wakeup-allow: it ticks only while its window is open (a debug or env-gated surface), on that thread.
        let link = displayLink(target: target, selector: #selector(NativeTranscriptLinkTarget.tick(_:)))
        let made = NativeTranscriptThread(layer: metalLayer, size: bounds.size, scale: scale, link: link, target: target) { [weak self] renderer in
            MainDelivery().run { self?.started(renderer) }
        }
        thread = made
        made.start()
    }

    private func started(_ made: NativeTranscriptRenderer?) {
        renderer = made
        ready = true
        let waiting = onReady
        onReady.removeAll()
        for then in waiting { then(made) }
    }

    /// Stops the link and the render thread; the scene is freed there.
    func stop() {
        thread?.stop()
        thread = nil
        renderer = nil
        ready = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let scale = window?.backingScaleFactor ?? metalLayer.contentsScale
        renderer?.post { $0.resize(newSize, scale: scale) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor else { return }
        metalLayer.contentsScale = scale
        let size = bounds.size
        renderer?.post { $0.resize(size, scale: scale) }
    }

    override func scrollWheel(with event: NSEvent) {
        // Positive scrolls toward the end: a wheel's positive delta moves the content down (toward the top).
        let delta = -Double(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16)
        renderer?.post { $0.scroll(by: delta) }
    }
}

/// The display link's target: ticks the renderer on the render thread with the link's clock.
// crash-allow: `renderer` is set once on the render thread before the link is added to its run loop, then read only by `tick` on that thread.
nonisolated final class NativeTranscriptLinkTarget: NSObject, @unchecked Sendable {
    var renderer: NativeTranscriptRenderer?

    @objc func tick(_ link: CADisplayLink) {
        renderer?.tick(now: link.targetTimestamp, refresh: link.targetTimestamp - link.timestamp)
    }
}

/// The render thread of one native transcript: makes the renderer, schedules the display link on its own run loop
/// and runs that loop until `stop`, which invalidates the link on this thread and frees the renderer here.
// crash-allow: `link`, `layer` and `target` are handed to the thread before it starts and used only on it after; `state` is a Mutex.
nonisolated final class NativeTranscriptThread: @unchecked Sendable {
    private struct State { var stopped = false; var loop: CFRunLoop? }
    private let layer: CAMetalLayer
    private let size: CGSize
    private let scale: CGFloat
    private let link: CADisplayLink
    private let target: NativeTranscriptLinkTarget
    private let ready: @Sendable (NativeTranscriptRenderer?) -> Void
    // concurrency-allow: the stop flag and the run loop the stop ends; set by main and the render thread, read between run loop passes; no work under it.
    private let state = Mutex(State())

    init(layer: CAMetalLayer, size: CGSize, scale: CGFloat, link: CADisplayLink, target: NativeTranscriptLinkTarget,
         ready: @escaping @Sendable (NativeTranscriptRenderer?) -> Void) {
        self.layer = layer
        self.size = size
        self.scale = scale
        self.link = link
        self.target = target
        self.ready = ready
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "cmux-next native transcript render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// From main: ends the render thread's run loop (CFRunLoopStop is thread-safe); the thread then invalidates
    /// the link and frees the renderer. Before the loop exists, the thread sees the flag and never schedules the link.
    func stop() {
        let loop = state.withLock { current -> CFRunLoop? in
            current.stopped = true
            return current.loop
        }
        if let loop { CFRunLoopStop(loop) }
    }

    private func run() {
        let made = autoreleasepool { NativeTranscriptRenderer.make(layer: layer, size: size, scale: scale) }
        let going = state.withLock { current -> Bool in
            guard !current.stopped, made != nil else { return false }
            current.loop = CFRunLoopGetCurrent()
            return true
        }
        guard going, let made else {
            link.invalidate()
            ready(nil)
            return
        }
        target.renderer = made
        let loop = RunLoop.current
        loop.add(NSMachPort(), forMode: .default)  // keeps the loop alive between link ticks
        link.add(to: loop, forMode: .common)
        ready(made)
        while !state.withLock({ $0.stopped }) {
            // A pass at most a second long: a stop that lands between the flag read and the pass is seen next pass.
            // concurrency-allow: the render thread's own top-level run loop (never main, never nested in another).
            _ = autoreleasepool { loop.run(mode: .default, before: Date(timeIntervalSinceNow: 1)) }
        }
        link.invalidate()
        target.renderer = nil
    }
}
#endif
