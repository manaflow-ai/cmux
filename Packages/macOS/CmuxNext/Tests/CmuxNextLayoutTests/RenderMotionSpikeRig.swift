import AppKit
@testable import CmuxNextLayout
import CmuxNextRemoteLayer
import Foundation
import IOSurface
import QuartzCore
import Testing

// The spike's rig (RenderMotionSpikeTests): the spring math, the motion container candidate, the pane, the window
// and the capture reader.

/// A critically damped spring of mass 1 (`CASpringAnimation` stiffness w^2, damping 2w), the share of its start
/// offset an additive spring with initial velocity 0 still carries t seconds in: (1 + w t) e^(-w t).
nonisolated struct SpikeSpring: Sendable {
    /// The undamped angular frequency, in radians per second.
    let omega: Double

    /// The marks the tests read at: 25, 50 and 75 % of the way.
    static let marks: [Double] = [0.25, 0.5, 0.75]

    func remaining(at time: Double) -> Double {
        guard time > 0 else { return 1 }
        return (1 + omega * time) * exp(-omega * time)
    }

    /// Seconds until `progress` (0 to 1) of the way is covered.
    func time(atProgress progress: Double) -> Double {
        var low = 0.0, high = 60 / omega
        for _ in 0..<64 {
            let middle = (low + high) / 2
            if 1 - remaining(at: middle) < progress { low = middle } else { high = middle }
        }
        return high
    }

    /// Seconds until less than a thousandth of the offset remains.
    var settlingTime: Double { time(atProgress: 0.999) }

    /// The additive spring of `keyPath` from `delta` to zero, starting at `beginTime` (the layer's time).
    func animation(_ keyPath: String, from delta: NSValue, zero: NSValue, beginTime: CFTimeInterval) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = omega * omega
        animation.damping = 2 * omega
        animation.initialVelocity = 0
        animation.duration = settlingTime
        animation.fromValue = delta
        animation.toValue = zero
        animation.isAdditive = true
        animation.beginTime = beginTime
        return animation
    }
}

/// The motion container candidate: a layer-backed view around a pane host that only motion code sizes. Its layer
/// carries the pane's springs and its rounded clip. It keeps the springs it runs, so a backing layer AppKit
/// makes again (a `wantsLayer` change) starts with them at their begin time and what shows goes on from the same
/// value. Chrome keys an animation by its element id, not by the layer object, for the same reason
/// (cc/animation/animation_host.h, cc/animation/element_animations.h).
final class SpikeMotionContainerView: NSView {
    private let cornerRadius: CGFloat
    private var springs: [String: CAAnimation] = [:]

    init(frame: CGRect, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        autoresizingMask = []
        autoresizesSubviews = true
        configure(layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        configure(layer)
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        springs = springs.filter { $0.value.beginTime + $0.value.duration > now }
        for (key, spring) in springs { layer.add(spring, forKey: key) }
        return layer
    }

    func addSpring(_ spring: CAAnimation, forKey key: String) {
        springs[key] = spring
        layer?.add(spring, forKey: key)
    }

    private func configure(_ layer: CALayer?) {
        layer?.masksToBounds = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .circular
    }
}

/// The view that holds the panes, as `ScreenContentView` does: its `layout()` writes each pane's frame from the
/// pane's rest, scaled to its bounds and moved by `nudge`. An ancestor resize, a window frame change and a layout
/// pass then write a new frame to a springing view.
final class SpikeScreenView: NSView {
    private var rests: [(view: NSView, rest: CGRect)] = []
    private let reference: CGSize

    /// Points every pane's frame moves by: a layout that places the panes again somewhere else.
    var nudge = CGVector.zero {
        didSet { needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        reference = frameRect.size
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        autoresizesSubviews = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Sets the rest of `view` (in the coordinates of the screen's first size) and writes its frame now.
    func place(_ view: NSView, rest: CGRect) {
        if let index = rests.firstIndex(where: { $0.view === view }) {
            rests[index].rest = rest
        } else {
            rests.append((view: view, rest: rest))
        }
        view.frame = placed(rest)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for entry in rests {
            let frame = placed(entry.rest)
            if entry.view.frame != frame { entry.view.frame = frame }
        }
    }

    private func placed(_ rest: CGRect) -> CGRect {
        let scaleX = bounds.width / max(1, reference.width), scaleY = bounds.height / max(1, reference.height)
        return CGRect(x: rest.minX * scaleX + nudge.dx, y: rest.minY * scaleY + nudge.dy,
                      width: rest.width * scaleX, height: rest.height * scaleY)
    }
}

/// What a disturbing event did to the springing view, so that a case whose event did nothing cannot pass.
nonisolated struct SpikeEventEffect: Sendable {
    /// The springing view has another layer than before the event.
    let layerReplaced: Bool
    /// The model frame of the springing layer changed during the event.
    let modelFrameWritten: Bool
}

/// One pane: a real `PaneHostView` with layer-backed content, and for the container candidate the container
/// around it.
final class SpikePane {
    let kind: SpikeLayer
    let host: PaneHostView
    let content: NSView
    let container: SpikeMotionContainerView?
    private let screen: SpikeScreenView
    private var spring = SpikeSpring(omega: 2)
    private var begin: CFTimeInterval = 0
    private var positionDelta = CGPoint.zero
    private var sizeDelta = CGSize.zero
    private weak var springLayer: CALayer?
    private let stripClip: Bool

    /// The view whose layer carries the springs.
    var animated: NSView { container ?? host }

    init(_ kind: SpikeLayer, frame: CGRect, cornerRadius: CGFloat, stripClip: Bool, in screen: SpikeScreenView) {
        let content = NSView(frame: .zero)
        content.wantsLayer = true
        let host = PaneHostView(pane: PaneID("spike"), content: content)
        let container = kind == .motionContainer ? SpikeMotionContainerView(frame: frame, cornerRadius: cornerRadius) : nil
        if let container {
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            screen.addSubview(container)
            screen.place(container, rest: frame)
        } else {
            host.autoresizingMask = []
            screen.addSubview(host)
            screen.place(host, rest: frame)
        }
        host.applyShape(padding: 0, cornerRadius: cornerRadius)
        self.kind = kind
        self.stripClip = stripClip
        self.content = content
        self.host = host
        self.container = container
        self.screen = screen
        applyStripClip()
        host.layoutSubtreeIfNeeded()
    }

    /// A docked column's strip clip, as the layout gives a pane it covers: the host's own mask, at rest.
    private func applyStripClip() {
        if stripClip { host.setStripClip(host.bounds.insetBy(dx: 0, dy: 4)) }
    }

    /// Whether AppKit gave the springing view another layer since the spring started.
    var layerReplaced: Bool { animated.layer !== springLayer }

    /// Sets the frame to `rest` at once, then springs what shows from the old frame to it.
    func spring(to rest: CGRect, with spring: SpikeSpring) {
        guard let layer = animated.layer else { return }
        let position = layer.position, size = layer.bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screen.place(animated, rest: rest)
        applyStripClip()
        animated.layoutSubtreeIfNeeded()
        CATransaction.commit()
        start(spring, on: layer,
              position: CGPoint(x: position.x - layer.position.x, y: position.y - layer.position.y),
              size: CGSize(width: size.width - layer.bounds.width, height: size.height - layer.bounds.height))
    }

    /// Springs the size alone from `size` to the current one (the frame stays).
    func springSize(from size: CGSize, with spring: SpikeSpring) {
        guard let layer = animated.layer else { return }
        start(spring, on: layer, position: .zero,
              size: CGSize(width: size.width - layer.bounds.width, height: size.height - layer.bounds.height))
    }

    private func start(_ spring: SpikeSpring, on layer: CALayer, position: CGPoint, size: CGSize) {
        self.spring = spring
        positionDelta = position
        sizeDelta = size
        begin = CACurrentMediaTime()
        springLayer = layer
        let local = layer.convertTime(begin, from: nil)
        add(spring.animation("position", from: NSValue(point: position), zero: NSValue(point: .zero), beginTime: local),
            key: "spike.position", to: layer)
        add(spring.animation("bounds.size", from: NSValue(size: size), zero: NSValue(size: .zero), beginTime: local),
            key: "spike.size", to: layer)
    }

    private func add(_ animation: CAAnimation, key: String, to layer: CALayer) {
        if let container { container.addSpring(animation, forKey: key) } else { layer.add(animation, forKey: key) }
    }

    /// Media time of `progress` of the way.
    func time(atProgress progress: Double) -> CFTimeInterval { begin + spring.time(atProgress: progress) }

    /// How far the presented geometry is from model + spring offset now, in points: the largest miss of the
    /// four components, past the offsets one frame either side of the read. Infinite with no presentation.
    func offsetError() -> CGFloat {
        guard let layer = animated.layer else { return .infinity }
        let before = CACurrentMediaTime() - begin
        guard let shown = layer.presentation() else { return .infinity }
        let after = CACurrentMediaTime() - begin
        let frame = 1.0 / 60
        let early = CGFloat(spring.remaining(at: before - frame)), late = CGFloat(spring.remaining(at: after + frame))
        func miss(_ measured: CGFloat, _ delta: CGFloat) -> CGFloat {
            let low = min(delta * early, delta * late), high = max(delta * early, delta * late)
            return measured < low ? low - measured : measured > high ? measured - high : 0
        }
        return max(miss(shown.position.x - layer.position.x, positionDelta.x),
                   miss(shown.position.y - layer.position.y, positionDelta.y),
                   miss(shown.bounds.width - layer.bounds.width, sizeDelta.width),
                   miss(shown.bounds.height - layer.bounds.height, sizeDelta.height))
    }

    /// The rect the springing layer presents, in window coordinates.
    func presentedFrameInWindow() -> CGRect? {
        guard let shown = animated.layer?.presentation(), let superview = animated.superview else { return nil }
        return superview.convert(shown.frame, to: nil)
    }
}

/// A window with an unflipped screen view that holds and lays out the panes, and a Core Animation clock to wait on.
final class SpikeRig {
    let window: NSWindow
    let screen: SpikeScreenView
    private let clock = CALayer()
    private var clockTicks = 0
    private var remote: (context: NSObject, root: CALayer, id: UInt32)?
    private var surface: IOSurface?

    init(size: CGSize, styleMask: NSWindow.StyleMask = [.titled, .resizable]) throws {
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 120, y: 120), size: size), styleMask: styleMask,
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .black
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = root
        screen = SpikeScreenView(frame: root.bounds)
        root.addSubview(screen)
        root.layer?.addSublayer(clock)
        clock.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        window.orderFrontRegardless()
        try #require(window.screen != nil, "the window is on no screen")
        root.layoutSubtreeIfNeeded()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    func addPane(_ kind: SpikeLayer, frame: CGRect, cornerRadius: CGFloat = 10, stripClip: Bool = false) -> SpikePane {
        SpikePane(kind, frame: frame, cornerRadius: cornerRadius, stripClip: stripClip, in: screen)
    }

    /// Adds a red `leaf` 40 pt larger than the pane on every side to its content.
    func addLeaf(_ leaf: SpikeLeaf, to pane: SpikePane) throws {
        let frame = pane.content.bounds.insetBy(dx: -40, dy: -40)
        let layer: CALayer
        switch leaf {
        case .ioSurface:
            let red = try #require(surface ?? Self.redSurface(width: 64, height: 64), "IOSurface creation failed")
            surface = red
            layer = CALayer()
            layer.contents = red
            layer.contentsGravity = .resize
        case .layerHost:
            let context = try #require(remote ?? Self.redRemoteContext(size: CGSize(width: 2000, height: 2000)),
                                       "no CAContext: the QuartzCore SPI Chromium uses is missing")
            remote = context
            let host = CALayerHost()
            host.contextId = context.id
            layer = host
        }
        layer.frame = frame
        pane.content.layer?.addSublayer(layer)
    }

    /// Resumes at media time `time` from a Core Animation completion: the wait runs on the render server's
    /// clock and leaves the main thread free. A clock animation AppKit removed early is added again. Each wait
    /// has its own key, so waits that overlap (a deadline and a sample) never replace each other's tick.
    func wait(untilMediaTime time: CFTimeInterval) async {
        while time - CACurrentMediaTime() > 0.002 {
            let left = time - CACurrentMediaTime()
            clockTicks += 1
            let key = "spike.clock.\(clockTicks)"
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                CATransaction.begin()
                CATransaction.setCompletionBlock { continuation.resume() }
                let tick = CABasicAnimation(keyPath: "opacity")
                tick.fromValue = 1
                tick.toValue = 1
                tick.duration = left
                clock.add(tick, forKey: key)
                CATransaction.commit()
            }
        }
    }

    /// The pane's offset error at 25, 50 and 75 % of the way; fails when a mark passed before it could be read.
    func sample(_ pane: SpikePane, spring: SpikeSpring) async throws -> [CGFloat] {
        var errors: [CGFloat] = []
        for mark in SpikeSpring.marks {
            let at = pane.time(atProgress: mark)
            try #require(CACurrentMediaTime() < at, "the \(Int(mark * 100)) % mark passed before it was read")
            await wait(untilMediaTime: at)
            errors.append(pane.offsetError())
        }
        return errors
    }

    /// Applies `event` to the pane mid-spring and says what it did to the springing view.
    func disturb(_ event: SpikeEvent, pane: SpikePane) -> SpikeEventEffect {
        let layerBefore = pane.animated.layer
        let frameBefore = layerBefore?.frame
        switch event {
        case .control:
            break
        case .appKitLayout:
            pane.content.frame = pane.content.frame.insetBy(dx: 2, dy: 2)
            screen.nudge = CGVector(dx: 2, dy: 2)
            let views: [NSView] = [screen, pane.animated, pane.host, pane.content]
            for view in views { view.needsLayout = true }
            window.contentView?.layoutSubtreeIfNeeded()
            let rest = pane.animated.frame
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                pane.animated.animator().frame = rest
            }
            window.displayIfNeeded()
        case .ancestorSetFrame:
            screen.setFrameOrigin(NSPoint(x: screen.frame.minX + 30, y: screen.frame.minY + 20))
            screen.setFrameSize(NSSize(width: screen.frame.width + 80, height: screen.frame.height + 40))
            window.contentView?.layoutSubtreeIfNeeded()
            window.setFrame(window.frame.insetBy(dx: -40, dy: -30), display: true)
            window.contentView?.layoutSubtreeIfNeeded()
        case .wantsLayer:
            pane.animated.wantsLayer = false
            window.displayIfNeeded()
            pane.animated.wantsLayer = true
            window.displayIfNeeded()
        case .ancestorWantsLayer:
            screen.wantsLayer = false
            window.displayIfNeeded()
            screen.wantsLayer = true
            window.displayIfNeeded()
        case .layerReassigned:
            pane.animated.layer = pane.animated.makeBackingLayer()
            window.displayIfNeeded()
        case .windowStyleChange:
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            if let visible = window.screen?.visibleFrame { window.setFrame(visible, display: true) }
            window.contentView?.layoutSubtreeIfNeeded()
        }
        let layerAfter = pane.animated.layer
        return SpikeEventEffect(layerReplaced: layerAfter !== layerBefore, modelFrameWritten: layerAfter?.frame != frameBefore)
    }

    /// Enters or leaves full screen; false when the window did not get there by media time `deadline`.
    func toggleFullScreen(entering: Bool, deadline: CFTimeInterval) async -> Bool {
        let name = entering ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
        let once = SpikeOnce()
        let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { once.finish(true) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.toggleFullScreen(nil)
        return await withCheckedContinuation { continuation in
            once.wait(continuation)
            Task { @MainActor in
                await self.wait(untilMediaTime: deadline)
                once.finish(false)
            }
        }
    }

    /// A 64 x 64 opaque red BGRA surface.
    private static func redSurface(width: Int, height: Int) -> IOSurface? {
        let bgra: UInt32 = 0x4247_5241
        guard let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4, .pixelFormat: bgra])
        else { return nil }
        _ = surface.lock(options: [], seed: nil)
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width {
                let pixel = base + row * surface.bytesPerRow + column * 4
                pixel[0] = 0
                pixel[1] = 0
                pixel[2] = 255
                pixel[3] = 255
            }
        }
        _ = surface.unlock(options: [], seed: nil)
        return surface
    }

    /// A Core Animation context of this process whose root layer is solid red, for a CALayerHost to show by id:
    /// `+[CAContext contextWithCGSConnection:options:]` on `CGSMainConnectionID()`, as Chromium makes one
    /// (ui/base/cocoa/remote_layer_api.h). Nil when this macOS lacks the SPI.
    private static func redRemoteContext(size: CGSize) -> (context: NSObject, root: CALayer, id: UInt32)? {
        let selector = NSSelectorFromString("contextWithCGSConnection:options:")
        guard let contextClass = NSClassFromString("CAContext"),
              let method = class_getClassMethod(contextClass, selector),
              let connectionSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID") else { return nil }
        typealias MainConnection = @convention(c) () -> UInt32
        typealias MakeContext = @convention(c) (AnyObject, Selector, UInt32, NSDictionary) -> Unmanaged<NSObject>?
        let connection = unsafeBitCast(connectionSymbol, to: MainConnection.self)()
        let make = unsafeBitCast(method_getImplementation(method), to: MakeContext.self)
        guard let context = make(contextClass as AnyObject, selector, connection, NSDictionary())?.takeUnretainedValue() else { return nil }
        let root = CALayer()
        root.anchorPoint = .zero
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = NSColor.red.cgColor
        context.setValue(root, forKey: "layer")
        guard let id = (context.value(forKey: "contextId") as? NSNumber)?.uint32Value, id != 0 else { return nil }
        return (context, root, id)
    }
}

/// Resumes a continuation once with the first of a notification and a deadline, also when that came first.
final class SpikeOnce {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait(_ continuation: CheckedContinuation<Bool, Never>) {
        if let result { continuation.resume(returning: result) } else { self.continuation = continuation }
    }

    func finish(_ value: Bool) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

extension SpikeRig {
    /// Pane frames for a 3-row grid of columns with the given relative widths (a zero width keeps a 40 pt column).
    static func gridFrames(columns: [CGFloat], in bounds: CGRect) -> [CGRect] {
        let total = columns.reduce(0, +)
        var x = bounds.minX
        var frames: [CGRect] = []
        for share in columns {
            let width = max(40, (bounds.width - 40 * CGFloat(columns.filter { $0 == 0 }.count)) * share / total)
            for row in 0..<3 {
                let height = bounds.height / 3
                frames.append(CGRect(x: x, y: bounds.minY + CGFloat(row) * height, width: width, height: height).insetBy(dx: 4, dy: 4))
            }
            x += width
        }
        return frames
    }
}

/// A point to read in the capture and whether the red leaf should show there.
nonisolated struct SpikeClipProbe: Sendable {
    let name: String
    let point: CGPoint
    let red: Bool

    /// For a rounded rect `shown` (window coordinates, 14 pt corners): red inside, the window's black in the
    /// corner the rounding cuts and just past the presented edge (where the rest frame and the leaf reach).
    static func probes(in shown: CGRect) -> [SpikeClipProbe] {
        [SpikeClipProbe(name: "center", point: CGPoint(x: shown.midX, y: shown.midY), red: true),
         SpikeClipProbe(name: "insideLeftEdge", point: CGPoint(x: shown.minX + 4, y: shown.midY), red: true),
         SpikeClipProbe(name: "roundedCorner", point: CGPoint(x: shown.minX + 2, y: shown.minY + 2), red: false),
         SpikeClipProbe(name: "pastRightEdge", point: CGPoint(x: shown.maxX + 6, y: shown.midY), red: false),
         SpikeClipProbe(name: "pastTopEdge", point: CGPoint(x: shown.midX, y: shown.maxY + 6), red: false)]
    }
}

/// A window capture as RGBA bytes, read in window coordinates (origin bottom left, as AppKit's).
nonisolated struct SpikePixels: Sendable {
    let width: Int
    let height: Int
    let scale: CGFloat
    let bytes: [UInt8]

    init?(_ image: CGImage, window size: CGSize) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.scale = CGFloat(width) / max(1, size.width)
        self.bytes = bytes
    }

    func isRed(at point: CGPoint) -> Bool {
        let x = Int(point.x * scale), y = Int(CGFloat(height) - point.y * scale)
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        let index = (y * width + x) * 4
        return bytes[index] > 160 && bytes[index + 1] < 90 && bytes[index + 2] < 90
    }
}
