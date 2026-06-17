#if canImport(AppKit)
import AppKit
import QuartzCore

/// A native, layer-backed view that renders an RFB framebuffer and forwards
/// mouse/keyboard input to the server. No WebKit, no intermediate bitmap
/// server: decoded BGRX pixels go straight into a `CALayer` as a `CGImage`,
/// and the GPU compositor scales them aspect-fit.
@MainActor
public final class VNCSurfaceView: NSView {
    private let client: RFBClient
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var remoteSize = CGSize.zero
    private var currentButtons: VNCButtonMask = []
    private var activeModifiers: Set<UInt32> = []
    private var trackingAreaRef: NSTrackingArea?

    private var inputContinuation: AsyncStream<InputCommand>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    /// Called on the main actor for every client event (state, bell, clipboard).
    public var onEvent: ((VNCClientEvent) -> Void)?

    /// Called when the user interacts (mouse/keys) so the host can mark this
    /// surface focused in its own model.
    public var onFocusRequested: (() -> Void)?

    public init(client: RFBClient) {
        self.client = client
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        // Remote desktops are usually shown smaller than their native size
        // (downscaled). Default `.linear` minification without mipmaps looks
        // soft/blurry; trilinear (mipmapped) keeps text crisp when shrinking,
        // and nearest keeps it sharp when enlarging.
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .nearest
        startInputPump()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Keep the layer's backing resolution matched to the screen so the
    /// framebuffer is rasterised at native Retina density, not upscaled from 1x.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
        }
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Lifecycle

    /// Begins the session: consumes client events, rendering frames as they land.
    public func connect() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            guard let stream = await self?.client.start() else { return }
            for await event in stream {
                guard let self else { break }
                await self.handle(event)
            }
        }
    }

    public func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        Task { [client] in await client.stop() }
    }

    deinit {
        inputContinuation?.finish()
        pumpTask?.cancel()
        eventTask?.cancel()
    }

    private func handle(_ event: VNCClientEvent) async {
        switch event {
        case .connected(let width, let height, _), .resized(let width, let height):
            remoteSize = CGSize(width: width, height: height)
        case .frame(let snapshot):
            render(snapshot)
        case .serverCutText(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        default:
            break
        }
        onEvent?(event)
    }

    // MARK: Rendering

    private func render(_ snapshot: VNCFrameSnapshot) {
        guard snapshot.width > 0, snapshot.height > 0 else { return }
        remoteSize = CGSize(width: snapshot.width, height: snapshot.height)
        let bytesPerRow = snapshot.width * 4
        guard snapshot.pixels.count >= bytesPerRow * snapshot.height else { return }
        guard let provider = CGDataProvider(data: snapshot.pixels as CFData) else { return }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let image = CGImage(
            width: snapshot.width,
            height: snapshot.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit fade between frames
        layer?.contents = image
        CATransaction.commit()
    }

    /// The rectangle (in view coords) the framebuffer image occupies, aspect-fit.
    private var displayedRect: CGRect {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return bounds }
        let scale = min(bounds.width / remoteSize.width, bounds.height / remoteSize.height)
        let width = remoteSize.width * scale
        let height = remoteSize.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// Maps a view point to remote framebuffer coordinates, or `nil` if outside.
    private func remotePoint(for event: NSEvent) -> (x: Int, y: Int)? {
        let local = convert(event.locationInWindow, from: nil)
        let rect = displayedRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let scaleX = remoteSize.width / rect.width
        let scaleY = remoteSize.height / rect.height
        let rx = (local.x - rect.minX) * scaleX
        let ry = (local.y - rect.minY) * scaleY
        let cx = Int(rx.rounded(.down))
        let cy = Int(ry.rounded(.down))
        let clampedX = min(max(0, cx), Int(remoteSize.width) - 1)
        let clampedY = min(max(0, cy), Int(remoteSize.height) - 1)
        return (clampedX, clampedY)
    }

    // MARK: Input pump (preserves event order)

    private enum InputCommand: Sendable {
        case pointer(buttons: VNCButtonMask, x: Int, y: Int)
        case key(keysym: UInt32, down: Bool)
        case scroll(up: Bool, x: Int, y: Int, ticks: Int)
    }

    private func startInputPump() {
        let stream = AsyncStream<InputCommand> { continuation in
            self.inputContinuation = continuation
        }
        pumpTask = Task { [client] in
            for await command in stream {
                switch command {
                case .pointer(let buttons, let x, let y):
                    await client.sendPointer(buttons: buttons, x: x, y: y)
                case .key(let keysym, let down):
                    await client.sendKey(keysym: keysym, down: down)
                case .scroll(let up, let x, let y, let ticks):
                    await client.sendScroll(up: up, x: x, y: y, ticks: ticks)
                }
            }
        }
    }

    private func enqueue(_ command: InputCommand) {
        inputContinuation?.yield(command)
    }

    private func sendPointer(for event: NSEvent) {
        guard let point = remotePoint(for: event) else { return }
        enqueue(.pointer(buttons: currentButtons, x: point.x, y: point.y))
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) { onFocusRequested?(); window?.makeFirstResponder(self); currentButtons.insert(.left); sendPointer(for: event) }
    public override func mouseUp(with event: NSEvent) { currentButtons.remove(.left); sendPointer(for: event) }
    public override func mouseDragged(with event: NSEvent) { sendPointer(for: event) }
    public override func rightMouseDown(with event: NSEvent) { currentButtons.insert(.right); sendPointer(for: event) }
    public override func rightMouseUp(with event: NSEvent) { currentButtons.remove(.right); sendPointer(for: event) }
    public override func rightMouseDragged(with event: NSEvent) { sendPointer(for: event) }
    public override func otherMouseDown(with event: NSEvent) { currentButtons.insert(.middle); sendPointer(for: event) }
    public override func otherMouseUp(with event: NSEvent) { currentButtons.remove(.middle); sendPointer(for: event) }
    public override func otherMouseDragged(with event: NSEvent) { sendPointer(for: event) }
    public override func mouseMoved(with event: NSEvent) { sendPointer(for: event) }

    public override func scrollWheel(with event: NSEvent) {
        guard let point = remotePoint(for: event) else { return }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let ticks = min(5, max(1, Int(abs(delta).rounded(.up) / 3)))
        enqueue(.scroll(up: delta > 0, x: point.x, y: point.y, ticks: ticks))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
        }
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard let keysym = VNCKeyMap.keysym(for: event) else { return }
        enqueue(.key(keysym: keysym, down: true))
        enqueue(.key(keysym: keysym, down: false))
    }

    public override func keyUp(with event: NSEvent) {
        // Key release is paired with the press above; nothing extra to send for
        // auto-repeat-style typing. Modifier transitions arrive via flagsChanged.
    }

    public override func flagsChanged(with event: NSEvent) {
        for flag in VNCKeyMap.trackedModifiers {
            guard let keysym = VNCKeyMap.modifierKeysym(for: flag) else { continue }
            let isDown = event.modifierFlags.contains(flag)
            let wasDown = activeModifiers.contains(keysym)
            if isDown, !wasDown {
                activeModifiers.insert(keysym)
                enqueue(.key(keysym: keysym, down: true))
            } else if !isDown, wasDown {
                activeModifiers.remove(keysym)
                enqueue(.key(keysym: keysym, down: false))
            }
        }
    }
}
#endif
