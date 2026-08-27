import AppKit
import CmuxBrowser
import Foundation

/// AppKit surface for an out-of-process Chromium page.
///
/// `chrome-headless-shell` has no native NSView to embed. The managed session
/// streams compressed viewport frames over CDP; this view paints the latest frame and forwards
/// the minimum native input set back through CDP. The child process remains
/// fully isolated from cmux, including when its renderer crashes.
@MainActor
final class ChromiumBrowserHostView: NSView {
    private let imageView = NSImageView(frame: .zero)
    private weak var session: ChromiumBrowserSession?
    private let inputQueue: ChromiumInputEventQueue
    private let keyMapping = ChromiumKeyMapping()
    private var frameTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    private var pointerTrackingArea: NSTrackingArea?
    private var lastViewport: CGSize = .zero
    private var isSessionRunning = false
    private var hasStarted = false
    /// Whether this host is currently mounted as the visible pane owner.
    private var isPaneVisible = false
    private var screencastVisibilityTask: Task<Void, Never>?
    private var lastRequestedScreencastVisibility: Bool?

    private var deviceScaleFactor: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    var onSnapshot: ((ChromiumSessionSnapshot) -> Void)?
    var onInputFailure: ((any Error) -> Void)?
    var onFocus: (() -> Void)?

    init(session: ChromiumBrowserSession) {
        self.session = session
        self.inputQueue = ChromiumInputEventQueue(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        inputQueue.onFailure = { [weak self] error in
            self?.onInputFailure?(error)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        frameTask?.cancel()
        stateTask?.cancel()
        viewportTask?.cancel()
        screencastVisibilityTask?.cancel()
    }

    /// Fully decompresses one screencast frame into a bitmap-backed image.
    ///
    /// Runs off the main actor; the returned image draws without further
    /// decode work. Points-vs-pixels: the frame is retina-sized, so the
    /// image's logical size is set from the view-independent pixel size and
    /// the image view scales it to fit.
    nonisolated private static func decodedFrameImage(_ data: Data) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocus?()
        }
        return accepted
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        // The image view is presentation-only. Keep all pointer events on the
        // host so they can be translated into CDP input for the child process.
        return self
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        guard let session else { return }

        stateTask = Task { [weak self, weak session] in
            guard let session else { return }
            let snapshots = await session.snapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.onSnapshot?(snapshot)
                    if case .running = snapshot.state {
                        // The first layout can happen before the child/CDP
                        // connection is ready. Retry once at the transition
                        // into the running state; subsequent title/history
                        // snapshots must not resend identical geometry.
                        if !self.isSessionRunning {
                            self.isSessionRunning = true
                            self.lastViewport = .zero
                        }
                        self.updateViewportIfNeeded()
                    } else {
                        self.isSessionRunning = false
                    }
                }
            }
        }
        startFrameTaskIfNeeded()
        lastRequestedScreencastVisibility = nil
        requestScreencastVisibilityIfNeeded()
        updateViewportIfNeeded()
    }

    /// Updates frame delivery when this host moves between an active pane and
    /// a hidden tab. The session stops producing CDP screencast messages while
    /// hidden, and the decode task is cancelled so no JPEG work continues in
    /// the background.
    func setPaneVisible(_ visible: Bool) {
        let visibilityChanged = isPaneVisible != visible
        isPaneVisible = visible
        if visible {
            startFrameTaskIfNeeded()
        } else {
            frameTask?.cancel()
            frameTask = nil
            imageView.image = nil
        }
        if visibilityChanged {
            requestScreencastVisibilityIfNeeded()
        }
    }

    private func requestScreencastVisibilityIfNeeded() {
        guard lastRequestedScreencastVisibility != isPaneVisible else { return }
        lastRequestedScreencastVisibility = isPaneVisible
        screencastVisibilityTask?.cancel()
        guard let session else { return }
        let visible = isPaneVisible
        screencastVisibilityTask = Task { [weak session] in
            await session?.setScreencastEnabled(visible)
        }
    }

    private func startFrameTaskIfNeeded() {
        guard hasStarted, isPaneVisible, frameTask == nil, let session else { return }
        frameTask = Task { [weak self, weak session] in
            guard let session else { return }
            let frames = await session.frames()
            for await frame in frames {
                guard !Task.isCancelled else { return }
                // Decode eagerly off the main actor: `NSImage(data:)` defers
                // decompression to first draw, which would put the whole
                // JPEG decode on the main thread for every frame.
                // ImageIO decompression and bitmap allocation are CPU-bound;
                // keep them off the main actor that owns this AppKit view.
                let image = await Task.detached(priority: .userInitiated) {
                    Self.decodedFrameImage(frame)
                }.value
                guard !Task.isCancelled, let image else { return }
                await MainActor.run {
                    guard let self, self.isPaneVisible else { return }
                    self.imageView.image = image
                }
            }
        }
    }

    func stop() {
        frameTask?.cancel()
        stateTask?.cancel()
        viewportTask?.cancel()
        screencastVisibilityTask?.cancel()
        lastRequestedScreencastVisibility = nil
        inputQueue.cancel()
        frameTask = nil
        stateTask = nil
        viewportTask = nil
        hasStarted = false
        isSessionRunning = false
        lastViewport = .zero
        imageView.image = nil
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        updateViewportIfNeeded()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let replacement = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
            owner: self
        )
        addTrackingArea(replacement)
        pointerTrackingArea = replacement
    }

    private func updateViewportIfNeeded() {
        let size = bounds.size
        guard size.width > 1, size.height > 1, size != lastViewport else { return }
        lastViewport = size
        guard let session else { return }
        // CDP viewport dimensions are CSS points. The device scale factor is
        // sent separately so mouse coordinates and DOM geometry stay in the
        // same coordinate space as selector automation.
        let width = Int(ceil(size.width))
        let height = Int(ceil(size.height))
        viewportTask?.cancel()
        viewportTask = Task { [weak self, weak session] in
            guard let session else { return }
            do {
                try await session.setViewport(
                    width: max(1, width),
                    height: max(1, height),
                    deviceScaleFactor: max(1, Double(self?.deviceScaleFactor ?? 1))
                )
            } catch {
                await MainActor.run { self?.onInputFailure?(error) }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        focusForPointerInput()
        sendMouse(event, type: "mousePressed")
    }

    override func mouseUp(with event: NSEvent) {
        sendMouse(event, type: "mouseReleased")
    }

    override func rightMouseDown(with event: NSEvent) {
        focusForPointerInput()
        sendMouse(event, type: "mousePressed", button: "right")
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouse(event, type: "mouseReleased", button: "right")
    }

    override func otherMouseDown(with event: NSEvent) {
        focusForPointerInput()
        sendMouse(event, type: "mousePressed", button: "middle")
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouse(event, type: "mouseReleased", button: "middle")
    }

    override func mouseMoved(with event: NSEvent) {
        sendMouse(event, type: "mouseMoved", button: "none", clickCount: 0)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMouse(event, type: "mouseMoved", button: "left", clickCount: 0)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMouse(event, type: "mouseMoved", button: "right", clickCount: 0)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let x = Double(point.x)
        let y = Double(bounds.height - point.y)
        let deltaX = Double(event.scrollingDeltaX)
        let deltaY = Double(-event.scrollingDeltaY)
        inputQueue.enqueue(.mouse(
            type: "mouseWheel",
            x: x,
            y: y,
            button: "none",
            clickCount: 1,
            deltaX: deltaX,
            deltaY: deltaY
        ))
    }

    override func keyDown(with event: NSEvent) {
        sendKey(event, type: "keyDown")
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, type: "keyUp")
    }

    private func sendMouse(
        _ event: NSEvent,
        type: String,
        button: String? = nil,
        clickCount: Int? = nil
    ) {
        let point = convert(event.locationInWindow, from: nil)
        let x = Double(point.x)
        let y = Double(bounds.height - point.y)
        let resolvedButton = button ?? (event.buttonNumber == 2 ? "middle" : "left")
        let count = clickCount ?? max(1, event.clickCount)
        inputQueue.enqueue(.mouse(
            type: type,
            x: x,
            y: y,
            button: resolvedButton,
            clickCount: count,
            deltaX: 0,
            deltaY: 0
        ))
    }

    private func focusForPointerInput() {
        if window?.firstResponder === self {
            onFocus?()
        } else {
            window?.makeFirstResponder(self)
        }
    }

    private func sendKey(_ event: NSEvent, type: String) {
        let mapping = keyMapping.map(event)
        inputQueue.enqueue(.key(
            type: type,
            key: mapping.key,
            code: mapping.code,
            text: type == "keyDown" ? mapping.text : nil,
            modifiers: mapping.modifiers,
            windowsVirtualKeyCode: mapping.windowsVirtualKeyCode
        ))
    }
}
