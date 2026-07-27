import AppKit
import CmuxSimulator
import QuartzCore

/// A read-only host for the versioned packed-BGRA frame-ring protocol.
///
/// Capture producers stay outside the cmux process. This view maps the ring
/// read-only, deep-copies stable frames off-main, and presents only owned image
/// bytes to Core Animation.
@MainActor
public final class CmuxRemoteFrameView: NSView {
    public var onFirstFrame: (() -> Void)?
    public var onTransportFailure: ((Error) -> Void)?

    public private(set) var framePixelSize = CGSize.zero

    private var frameLayer: CALayer?
    private var framePipeline: SimulatorFramePresentationPipeline?
    private var frameTransportDescriptor: SimulatorFrameTransportDescriptor?
    private var presentationTimer: DispatchSourceTimer?
    private var lastFrameSequence: UInt64?
    private var isActive = true
    private var isTornDown = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
    }

    /// The frame view only presents pixels. Its host owns pointer input and
    /// translates it for the remote surface.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public func adopt(_ descriptor: SimulatorFrameTransportDescriptor) {
        guard !isTornDown, descriptor != frameTransportDescriptor else { return }
        let source: SimulatorFrameSurfaceSource
        do {
            source = try SimulatorFrameSurfaceSource(descriptor: descriptor)
        } catch {
            onTransportFailure?(error)
            return
        }

        stopPresentationTimer()
        retireFramePipeline()
        frameLayer?.removeFromSuperlayer()
        lastFrameSequence = nil

        let frameLayer = CALayer()
        frameLayer.contentsGravity = .resizeAspect
        frameLayer.minificationFilter = .linear
        frameLayer.magnificationFilter = .linear
        layer?.addSublayer(frameLayer)
        self.frameLayer = frameLayer
        framePipeline = SimulatorFramePresentationPipeline(
            source: source,
            presentationDidComplete: { [weak self] in
                self?.renderLatestFrame()
            }
        )
        frameTransportDescriptor = descriptor
        framePixelSize = CGSize(width: descriptor.width, height: descriptor.height)
        layoutFrameLayer()
        renderLatestFrame()
        reconcilePresentation()
    }

    public func setActive(_ active: Bool) {
        guard !isTornDown, active != isActive else { return }
        isActive = active
        reconcilePresentation()
    }

    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        NotificationCenter.default.removeObserver(self)
        stopPresentationTimer()
        retireFramePipeline()
        frameLayer?.removeFromSuperlayer()
        frameLayer = nil
        frameTransportDescriptor = nil
        framePixelSize = .zero
        lastFrameSequence = nil
        onFirstFrame = nil
        onTransportFailure = nil
    }

    public override func layout() {
        super.layout()
        layoutFrameLayer()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildPresentationTimer()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcilePresentation()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            stopPresentationTimer()
            NotificationCenter.default.removeObserver(self)
        }
        super.viewWillMove(toWindow: newWindow)
        guard let newWindow else { return }
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(hostWindowVisibilityDidChange(_:)),
                name: name,
                object: newWindow
            )
        }
    }

    private func renderLatestFrame() {
        guard
            isActive,
            let pipeline = framePipeline,
            let presentation = pipeline.displayTick(),
            presentation.sequence != lastFrameSequence,
            let frameLayer
        else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = presentation.image
        CATransaction.commit()
        let isFirstFrame = lastFrameSequence == nil
        lastFrameSequence = presentation.sequence
        if isFirstFrame {
            onFirstFrame?()
        }
    }

    private func layoutFrameLayer() {
        guard let frameLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds
        CATransaction.commit()
    }

    private func reconcilePresentation() {
        let shouldPresent = isActive
            && !isTornDown
            && framePipeline != nil
            && window.map(simulatorHostWindowIsVisible) == true
        if shouldPresent {
            startPresentationTimer()
            renderLatestFrame()
        } else {
            stopPresentationTimer()
        }
    }

    private func startPresentationTimer() {
        guard presentationTimer == nil, let framePipeline else { return }
        if framePipeline.setFramePublicationNotificationsEnabled(true) {
            return
        }
        let interval = simulatorPresentationTimerIntervalNanoseconds(
            maximumFramesPerSecond: window?.screen?.maximumFramesPerSecond
        )
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(interval),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.renderLatestFrame()
        }
        presentationTimer = timer
        timer.activate()
    }

    private func stopPresentationTimer() {
        presentationTimer?.setEventHandler(handler: nil)
        presentationTimer?.cancel()
        presentationTimer = nil
        framePipeline?.setFramePublicationNotificationsEnabled(false)
    }

    private func rebuildPresentationTimer() {
        guard !isTornDown, framePipeline != nil else { return }
        stopPresentationTimer()
        reconcilePresentation()
    }

    private func retireFramePipeline() {
        let pipeline = framePipeline
        framePipeline = nil
        frameLayer?.contents = nil
        pipeline?.invalidate()
    }

    @objc private func hostWindowVisibilityDidChange(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        reconcilePresentation()
    }
}
