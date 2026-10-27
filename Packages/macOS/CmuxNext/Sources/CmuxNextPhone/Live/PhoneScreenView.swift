public import AppKit
import AVFoundation
import CmuxNextInput
import CmuxNextInputCore
import CmuxNextWakeups
import IOSurface

/// The phone's screen inside a phone tab. It shows either the simulator's
/// own IOSurface (live: each SimulatorKit frame only marks the layer's
/// contents changed, no copy) or a still image. Mouse down, drag and up are
/// touches; typed keys go to the phone while it has focus. It reports when it
/// can be seen, so the tab stops frames while hidden.
@MainActor
public final class PhoneScreenView: NSView {
    private let content = CALayer()
    /// The layer's private `setContentsChanged`, resolved on the first repeated frame (nil when it lacks it).
    private lazy var markContentsChanged: (() -> Void)? = privateAction(content, "setContentsChanged")
    /// Hardware-decoded H.264 frames (Android live screens), shown over `content` while streaming.
    private var video: AVSampleBufferDisplayLayer?
    private var contentSize: CGSize = .zero
    private var occlusion: Task<Void, Never>?
    private var lastVisible: Bool?

    /// A touch at a 0...1 screen point (top-left origin).
    var onTouch: (@MainActor (PhoneTouch.Phase, CGPoint) -> Void)?
    /// A key change (Mac key code, down) while the screen has focus; return false to pass it on.
    var onKey: (@MainActor (UInt16, Bool) -> Bool)?
    /// Called when the screen becomes visible or hidden (tab switch, window occlusion, minimize).
    var onVisibilityChange: (@MainActor (Bool) -> Void)?
    /// The windows' frame-aligned pointer input (feature `pointerFrameRemoteInput`): touch moves reach
    /// the phone at most twice per display frame. Nil sends each drag event at once.
    var pointerFrames: FrameInputCoalescers? {
        didSet { if pointerFrames !== oldValue { dropFramePointer() } }
    }
    /// This view's consumer of its window's coalescer, made on the first drag in a window.
    private var framePointer: PointerFrameConsumer?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(content)
        content.contentsGravity = .resizeAspect
        content.cornerRadius = 18
        content.masksToBounds = true
        content.backgroundColor = NSColor.black.cgColor
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows a live surface. Call again with the same surface for every frame.
    func show(surface: IOSurface) {
        let size = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if content.contents as AnyObject? !== surface {
            content.contents = surface
        } else if let markContentsChanged {
            // Core Animation re-reads an IOSurface it already shows only when told its contents changed.
            markContentsChanged()
        } else {
            content.contents = nil
            content.contents = surface
        }
        CATransaction.commit()
        if size != contentSize {
            contentSize = size
            needsLayout = true
        }
    }

    /// Shows one compressed video frame (Android live screens); the layer decodes it.
    func show(sample: CMSampleBuffer) {
        let layer = video ?? {
            let made = AVSampleBufferDisplayLayer()
            made.videoGravity = .resizeAspect
            made.cornerRadius = 18
            made.masksToBounds = true
            self.layer?.addSublayer(made)
            video = made
            needsLayout = true
            return made
        }()
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
        if let format = CMSampleBufferGetFormatDescription(sample) {
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            let size = CGSize(width: Int(dims.width), height: Int(dims.height))
            if size != contentSize {
                contentSize = size
                needsLayout = true
            }
        }
    }

    /// Ends the video layer (the stream stopped); the still frame shows again.
    func endVideo() {
        video?.flushAndRemoveImage()
        video?.removeFromSuperlayer()
        video = nil
    }

    /// Shows a still frame (the `simctl` / `screencap` fallback).
    func show(image: NSImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        CATransaction.commit()
        contentSize = image?.size ?? .zero
        needsLayout = true
    }

    /// The screen as drawn now (aspect fit), for mapping clicks.
    var mapping: PhoneScreenMapping { PhoneScreenMapping(screen: contentSize, view: bounds.size) }

    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = mapping.drawnRect == .zero ? bounds : mapping.drawnRect
        video?.frame = content.frame
        CATransaction.commit()
    }

    // MARK: Input

    override public var acceptsFirstResponder: Bool { onKey != nil }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override public func mouseDown(with event: NSEvent) {
        flushPointer()
        window?.makeFirstResponder(self)
        touch(.began, at: event.locationInWindow)
    }

    /// A touch move; with ``pointerFrames`` a frame interval's first move goes at once and the rest
    /// once at the window's frame, to the latest point (Chromium's rAF-aligned input).
    override public func mouseDragged(with event: NSEvent) { // perf-hot: 2us pointer-coalesce (every drag over a phone screen)
        guard onTouch != nil else { return }
        if let consumer = framePointerConsumer() {
            consumer.post(event)
        } else {
            touch(.moved, at: event.locationInWindow)
        }
    }

    override public func mouseUp(with event: NSEvent) {
        // The last move lands before the touch ends.
        flushPointer()
        touch(.ended, at: event.locationInWindow)
    }

    private func touch(_ phase: PhoneTouch.Phase, at windowPoint: NSPoint) {
        let local = convert(windowPoint, from: nil)
        // Clamp drags that leave the screen so the touch still ends on it.
        let rect = mapping.drawnRect
        let clamped = CGPoint(x: min(max(local.x, rect.minX), rect.maxX), y: min(max(local.y, rect.minY), rect.maxY))
        guard let point = mapping.normalized(viewPoint: phase == .began ? local : clamped) else { return }
        onTouch?(phase, point)
    }

    override public func keyDown(with event: NSEvent) {
        flushPointer()
        // Command shortcuts stay with cmux; everything else types on the phone.
        if event.modifierFlags.contains(.command) || onKey?(event.keyCode, true) != true { super.keyDown(with: event) }
    }

    override public func keyUp(with event: NSEvent) {
        flushPointer()
        if event.modifierFlags.contains(.command) || onKey?(event.keyCode, false) != true { super.keyUp(with: event) }
    }

    // MARK: Frame-aligned touch moves

    /// Delivers the move that waits for the frame now: a touch edge or a key is about to go, and
    /// must not pass it.
    func flushPointer() { framePointer?.flush() }

    private func framePointerConsumer() -> PointerFrameConsumer? {
        if let framePointer { return framePointer }
        guard let pointerFrames, let window else { return nil }
        let consumer = pointerFrames.coalescer(for: window).consumer(owner: "PhoneScreenView") { [weak self] input in
            self?.touch(.moved, at: NSPoint(x: input.latest.location.x, y: input.latest.location.y))
        }
        framePointer = consumer
        return consumer
    }

    private func dropFramePointer() {
        framePointer?.cancel()
        framePointer = nil
    }

    // MARK: Visibility

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The coalescer is the old window's: what waits there is for a window the view left.
        dropFramePointer()
        occlusion?.cancel()
        occlusion = nil
        if let window {
            occlusion = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSWindow.didChangeOcclusionStateNotification, object: window) {
                    self?.reportVisibility()
                }
            }
        }
        reportVisibility()
    }

    override public func viewDidHide() {
        super.viewDidHide()
        reportVisibility()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        reportVisibility()
    }

    /// True while some part of the screen can be seen.
    public var isOnScreen: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.occlusionState.contains(.visible)
    }

    func reportVisibility() {
        let visible = isOnScreen
        guard visible != lastVisible else { return }
        lastVisible = visible
        onVisibilityChange?(visible)
    }

    /// Stops watching the window; the tab calls this when it closes.
    func close() {
        occlusion?.cancel()
        occlusion = nil
    }
}
