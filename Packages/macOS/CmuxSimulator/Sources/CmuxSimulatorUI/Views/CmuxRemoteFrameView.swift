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
    private static let hostWindowNotificationNames = [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification,
        NSWindow.willCloseNotification,
    ]

    /// Called once after the first frame from an adopted transport is presented.
    public var onFirstFrame: (() -> Void)?
    /// Called after each newly published frame is presented.
    public var onFramePresented: (() -> Void)?
    /// Called when the hosting window starts or stops being visible.
    public var onHostVisibilityChanged: ((Bool) -> Void)?
    /// Called when an adopted frame transport cannot be opened or read.
    public var onTransportFailure: ((CmuxRemoteFrameTransportFailure) -> Void)?

    /// Pixel dimensions of the currently adopted frame transport.
    public private(set) var framePixelSize = CGSize.zero
    /// Sequence of the frame currently installed in the presentation layer.
    public private(set) var presentedFrameSequence: UInt64?

    private var frameLayer: CALayer?
    private var framePresentationController:
        SimulatorFramePresentationController?
    private var frameTransportDescriptor: SimulatorFrameTransportDescriptor?
    private var transportMaximumFramesPerSecond: Int?
    private var hostWindowVisible = false
    private var isActive = true
    private var isTornDown = false
    private weak var observedHostWindow: NSWindow?

    /// Creates an empty remote-frame presentation view.
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
    /// Storyboard and archive construction are unsupported.
    public required init?(coder: NSCoder) {
        nil
    }

    /// Replaces the current frame transport with the supplied descriptor.
    @discardableResult
    public func adopt(
        _ descriptor: SimulatorFrameTransportDescriptor,
        maximumFramesPerSecond: Int? = nil
    ) -> Bool {
        guard !isTornDown else { return false }
        let maximumFramesPerSecond = maximumFramesPerSecond.map {
            min(max($0, 1), 120)
        }
        if descriptor == frameTransportDescriptor {
            guard maximumFramesPerSecond != transportMaximumFramesPerSecond else {
                return true
            }
            transportMaximumFramesPerSecond = maximumFramesPerSecond
            rebuildPresentationTimer()
            return true
        }
        let source: SimulatorFrameSurfaceSource
        do {
            source = try SimulatorFrameSurfaceSource(descriptor: descriptor)
        } catch {
            onTransportFailure?(.invalidTransport)
            return false
        }

        stopPresentationTimer()
        retireFramePipeline()
        frameLayer?.removeFromSuperlayer()
        presentedFrameSequence = nil

        let frameLayer = CALayer()
        frameLayer.contentsGravity = .resizeAspect
        frameLayer.minificationFilter = .linear
        frameLayer.magnificationFilter = .linear
        layer?.addSublayer(frameLayer)
        self.frameLayer = frameLayer
        framePresentationController = SimulatorFramePresentationController(
            source: source,
            presentationDidComplete: { [weak self] presentation in
                self?.render(presentation)
            },
            sourceFailureDidOccur: { [weak self] in
                guard let self else { return }
                // Keep the last owned frame visible, but revoke descriptor
                // equality so a restarted producer can reuse the same ring.
                frameTransportDescriptor = nil
                onTransportFailure?(.producerFailed)
            }
        )
        frameTransportDescriptor = descriptor
        transportMaximumFramesPerSecond = maximumFramesPerSecond
        framePixelSize = CGSize(width: descriptor.width, height: descriptor.height)
        layoutFrameLayer()
        renderLatestFrame()
        reconcilePresentation()
        return true
    }

    /// Enables or pauses presentation without releasing the current transport.
    public func setActive(_ active: Bool) {
        guard !isTornDown, active != isActive else { return }
        isActive = active
        reconcilePresentation()
    }

    /// Releases the mapped frame transport while keeping this view reusable.
    public func resetTransport() {
        guard !isTornDown else { return }
        stopPresentationTimer()
        retireFramePipeline()
        frameLayer?.removeFromSuperlayer()
        frameLayer = nil
        frameTransportDescriptor = nil
        transportMaximumFramesPerSecond = nil
        framePixelSize = .zero
        presentedFrameSequence = nil
    }

    /// Permanently stops presentation and clears callbacks.
    public func teardown() {
        guard !isTornDown else { return }
        stopObservingHostWindow()
        resetTransport()
        isTornDown = true
        publishHostVisibility(false)
        onFirstFrame = nil
        onFramePresented = nil
        onHostVisibilityChanged = nil
        onTransportFailure = nil
    }

    /// Keeps the presentation layer aligned with the view bounds.
    public override func layout() {
        super.layout()
        layoutFrameLayer()
    }

    /// Rebuilds the presentation cadence when display backing changes.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildPresentationTimer()
    }

    /// Reconciles presentation after the view enters or leaves a window.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcilePresentation()
    }

    /// Updates visibility observation before the hosting window changes.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            stopPresentationTimer()
            stopObservingHostWindow()
            publishHostVisibility(false)
        }
        super.viewWillMove(toWindow: newWindow)
        guard let newWindow, observedHostWindow !== newWindow else { return }
        observedHostWindow = newWindow
        for name in Self.hostWindowNotificationNames {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(hostWindowVisibilityDidChange(_:)),
                name: name,
                object: newWindow
            )
        }
    }

    private func stopObservingHostWindow() {
        for name in Self.hostWindowNotificationNames {
            NotificationCenter.default.removeObserver(
                self,
                name: name,
                object: observedHostWindow
            )
        }
        observedHostWindow = nil
    }

    private func renderLatestFrame() {
        guard isActive else { return }
        framePresentationController?.presentLatestFrame()
    }

    private func render(_ presentation: SimulatorFramePresentation) {
        guard
            isActive,
            presentation.sequence != presentedFrameSequence,
            let frameLayer
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = presentation.image
        CATransaction.commit()
        let isFirstFrame = presentedFrameSequence == nil
        presentedFrameSequence = presentation.sequence
        onFramePresented?()
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
        let hostWindowVisible = window.map(simulatorHostWindowIsVisible) == true
        publishHostVisibility(hostWindowVisible)
        let shouldPresent = isActive
            && !isTornDown
            && framePresentationController != nil
            && hostWindowVisible
        if shouldPresent {
            startPresentationTimer()
            renderLatestFrame()
        } else {
            stopPresentationTimer()
        }
    }

    private func startPresentationTimer() {
        framePresentationController?.startPresenting(
            maximumFramesPerSecond: presentationFramesPerSecond
        )
    }

    private func stopPresentationTimer() {
        framePresentationController?.stopPresenting()
    }

    private func rebuildPresentationTimer() {
        guard !isTornDown else { return }
        framePresentationController?.rebuildPresentationCadence(
            isVisible: isActive && hostWindowVisible,
            maximumFramesPerSecond: presentationFramesPerSecond
        )
        renderLatestFrame()
    }

    private func retireFramePipeline() {
        let controller = framePresentationController
        framePresentationController = nil
        frameLayer?.contents = nil
        controller?.invalidate()
    }

    private var presentationFramesPerSecond: Int? {
        simulatorPresentationFramesPerSecond(
            displayMaximumFramesPerSecond:
                window?.screen?.maximumFramesPerSecond,
            transportMaximumFramesPerSecond:
                transportMaximumFramesPerSecond
        )
    }

    @objc private func hostWindowVisibilityDidChange(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        if notification.name == NSWindow.willCloseNotification {
            publishHostVisibility(false)
            stopPresentationTimer()
            return
        }
        reconcilePresentation()
    }

    private func publishHostVisibility(_ visible: Bool) {
        guard visible != hostWindowVisible else { return }
        hostWindowVisible = visible
        onHostVisibilityChanged?(visible)
    }
}
