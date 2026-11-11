// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CmuxAgentCursor
import QuartzCore

/// The agent cursor (cursor.rs): one click-through, non-activating panel per screen an agent
/// session acts on, on every Space and over full-screen apps. It shows a cmux blue pointer with
/// the agent's name, and shows every interaction where it happens:
///
/// - move: the pointer glides there (spring motion, `GlideMotion`);
/// - click: one ripple per click (two for a double click), a dashed ring for a right click;
/// - typing: a caption with what is typed (shortened; no secret in full) and a caret;
/// - keys: the combo as key caps (⌘ ⇧ S);
/// - scroll: chevrons that run in the scroll's direction;
/// - drag: a trail from the start to the end, the pointer gliding along it;
/// - look (a screenshot or tree read): corner brackets frame the window looked at.
///
/// Each step also names itself in a chip under the agent's name ("Double-click", "Scroll").
/// The real pointer never moves. Agents never see the cursor in their screenshots: a display
/// capture leaves out this process's windows (ScreenCapture's own-process filter) and a window
/// capture shows only the target window. The person's own screen recordings and screen sharing
/// do show it, as they show a person's pointer.
///
/// Every layer draws at its screen's pixel density (`contentsScale`, set on every layer the
/// overlay makes, when it is made), so paths and text stay sharp on Retina.
///
/// Motion follows the app's cursor switches (``CursorMotionSettings``, from the host's config)
/// and macOS Reduce Motion: with animation off every change applies at once and nothing pulses.
@MainActor
final class AgentCursorOverlay {
    /// cursor.rs `IDLE_HIDE`.
    static let idleHide: TimeInterval = 4
    /// #0A84FF, cursor.rs `CMUX_BLUE`.
    static let blue = NSColor(srgbRed: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255, alpha: 1)
    /// The pointer's deeper tone (the bottom of its gradient).
    static let deepBlue = NSColor(srgbRed: 0x00 / 255, green: 0x5E / 255, blue: 0xE0 / 255, alpha: 1)

    var motion = CursorMotionSettings()
    /// `showCursor` off: events are ignored and every cursor hides.
    var enabled = true {
        didSet { if !enabled { hideAll() } }
    }
    private var cursors: [String: SessionCursor] = [:]
    /// Where each session's cursor last was (AppKit points) and its label, for Show Cursor after
    /// the cursor hid.
    private var lastSeen: [String: (tip: CGPoint, label: String)] = [:]
    private let reduceMotion: () -> Bool
    /// A real, invisible (alpha 0, 1 x 1 point, click-through) window ordered in from the start: a
    /// panel that was never ordered in has no window-server window, so ScreenCaptureKit would not
    /// list this process. With it, a display capture that leaves out this process's windows
    /// (`ScreenCapture`) always finds the process, and so also leaves out a cursor or approval
    /// panel that first appears during the capture.
    private let anchor = SessionCursor.makePanel(root: CALayer())

    init(reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.reduceMotion = reduceMotion
        anchor.alphaValue = 0
        anchor.ignoresMouseEvents = true
        anchor.setFrame(CGRect(x: 0, y: 0, width: 1, height: 1), display: false)
        anchor.orderFrontRegardless()
    }

    private var animates: Bool { motion.animates(reduceMotion: reduceMotion()) }

    func show(_ event: AgentCursorEvent) {
        if event.kind == .hide {
            cursors.removeValue(forKey: event.session)?.close(animated: false, speed: motion.speed)
            lastSeen.removeValue(forKey: event.session)
            return
        }
        guard enabled else { return }
        let isNew = cursors[event.session] == nil
        let cursor = cursors[event.session] ?? SessionCursor()
        cursors[event.session] = cursor
        cursor.label = event.label
        let geometry = AgentCursorGeometry(primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
        cursor.apply(event, geometry: geometry, animated: animates, speed: motion.speed)
        if isNew { cursor.startIdleWag(animated: animates, speed: motion.speed) }
        if let tip = cursor.currentTip { lastSeen[event.session] = (tip, event.label) }
        armIdleHide(cursor, session: event.session)
    }

    private func armIdleHide(_ cursor: SessionCursor, session: String) {
        cursor.armIdleHide(after: Self.idleHide) { [weak self] in
            guard let self, self.cursors[session] === cursor else { return }
            self.cursors.removeValue(forKey: session)?.close(animated: self.animates, speed: self.motion.speed)
        }
    }

    /// Show Cursor (the menu bar): rings spread from the session's cursor where it is, or where
    /// it last was if it hid, so the person finds it. False when the session never showed one.
    @discardableResult
    func spotlight(session: String) -> Bool {
        guard enabled else { return false }
        let cursor: SessionCursor
        if let shown = cursors[session] {
            cursor = shown
        } else if let last = lastSeen[session] {
            cursor = SessionCursor()
            cursor.label = last.label
            cursor.glide(to: last.tip, animated: false, speed: motion.speed)
            cursors[session] = cursor
        } else {
            return false
        }
        cursor.spotlight(animated: animates, speed: motion.speed)
        armIdleHide(cursor, session: session)
        return true
    }

    func hideAll() {
        for cursor in cursors.values { cursor.close(animated: false, speed: motion.speed) }
        cursors.removeAll()
    }

    var sessionCount: Int { cursors.count }

    static func render(_ events: [AgentCursorEvent], label: String, size: CGSize, scale: CGFloat,
                       backdrop: [(CGRect, NSColor)] = []) -> CGImage? {
        render(events, label: label, size: size, scale: scale, backdrop: backdrop) { _ in }
    }

    /// Draws one cursor after `events` (desktop points in a `size`-point space, top-left origin)
    /// into an image at `scale`, over a plain backdrop, with no window and no animation: the same
    /// layers the overlay shows, for tests and the detail catalog.
    fileprivate static func render(_ events: [AgentCursorEvent], label: String, size: CGSize, scale: CGFloat,
                                   backdrop: [(CGRect, NSColor)] = [], then extra: (SessionCursor) -> Void) -> CGImage? {
        let cursor = SessionCursor(offscreen: CGRect(origin: .zero, size: size), scale: scale)
        cursor.label = label
        let geometry = AgentCursorGeometry(primaryHeight: size.height)
        for event in events { cursor.apply(event, geometry: geometry, animated: false, speed: 1) }
        extra(cursor)
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        for (rect, color) in backdrop {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height))
        }
        cursor.draw(in: context)
        return context.makeImage()
    }

    /// The Show Cursor spotlight drawn offscreen (no animation: the rings at full size).
    static func renderSpotlight(label: String, size: CGSize, scale: CGFloat, at point: CGPoint,
                                backdrop: [(CGRect, NSColor)] = []) -> CGImage? {
        render([AgentCursorEvent(kind: .move, session: "s", label: label, at: point)], label: label, size: size,
               scale: scale, backdrop: backdrop) { $0.spotlight(animated: false, speed: 1) }
    }

    /// A glide's trail drawn offscreen as a still: the cursor at the end of a move from `from`
    /// to `to` with its comet tail laid along the path as it looks halfway through fading.
    static func renderTrail(label: String, size: CGSize, scale: CGFloat, from: CGPoint, to: CGPoint,
                            backdrop: [(CGRect, NSColor)] = []) -> CGImage? {
        render([AgentCursorEvent(kind: .move, session: "s", label: label, at: from)], label: label, size: size,
               scale: scale, backdrop: backdrop) { cursor in
            let geometry = AgentCursorGeometry(primaryHeight: size.height)
            cursor.stillTrail(to: geometry.appKit(to))
        }
    }

    /// The scroll's main direction as an arrow.
    static func arrow(_ v: CGVector) -> String {
        if abs(v.dy) >= abs(v.dx) { return v.dy >= 0 ? "\u{2193}" : "\u{2191}" }
        return v.dx >= 0 ? "\u{2192}" : "\u{2190}"
    }
}

/// What the chip under the agent's name shows.
enum CursorChip: Equatable {
    case text(String)
    case typing(String)
    case keys([String])
    /// The agent waits for the person (amber) or an action was refused (red). The pointer
    /// takes the same color until the next step.
    case alert(String, CursorAlert)
}

enum CursorAlert: Equatable {
    case paused
    case refused

    var color: NSColor {
        switch self {
        case .paused: NSColor(srgbRed: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)
        case .refused: NSColor(srgbRed: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)
        }
    }

    var textColor: NSColor { self == .paused ? NSColor(white: 0.1, alpha: 1) : .white }
}

/// One session's cursor: its panel (on the screen it is on) and layers. `body` holds the pointer,
/// the name and the chip and moves as one; effects (ripples, trails, frames) sit in `root` at
/// screen coordinates and remove themselves.
@MainActor
private final class SessionCursor {
    private var panel: NSPanel?
    private let root = CALayer()
    private let body = CALayer()
    /// The pointer and its tail, scaled and wagged as one around the tip.
    private let figure = CALayer()
    /// A thin deep-blue line outside the white rim, so the pointer reads on white too.
    private let rim = CAShapeLayer()
    private let tailEdge = CAShapeLayer()
    private let tail = CAShapeLayer()
    private let shadow = CAShapeLayer()
    private let pointer = CAShapeLayer()
    private let shine = CAGradientLayer()
    private let shineMask = CAShapeLayer()
    private let nameTag = CALayer()
    private let dot = CALayer()
    private let name = CATextLayer()
    private let chipLayer = CALayer()
    private var chipContent: [CALayer] = []
    private var chipTimer: Timer?
    /// The tip, in AppKit screen points.
    private var tip: CGPoint?
    private var hideTimer: Timer?
    private var idleTimer: Timer?
    private var scale: CGFloat = 2
    /// Drawn into an image instead of a panel (``AgentCursorOverlay/render``): this frame stands
    /// for the screen.
    private let offscreen: CGRect?
    /// The frame (AppKit screen points) of the screen the cursor is on.
    private var screenFrame: CGRect?
    var label = "" {
        didSet { if label != oldValue { layoutName() } }
    }

    /// The figure's scale over its design grid (a pointer about 30 pt tall: bigger than the
    /// person's own, so it reads as the agent's).
    static let k: CGFloat = 1.3
    static let pointerSize = CGSize(width: 24 * k, height: 28 * k)
    /// The widest the agent's name gets (points).
    static let maxNameWidth: CGFloat = 200
    /// The pointer's tip inside its bounds (y up).
    static let tipPoint = CGPoint(x: 2.5 * k, y: 26 * k)
    /// Where the tail leaves the pointer: the middle of the stem's end (design grid, y up).
    static let tailRoot = CGPoint(x: 12.8, y: 5.0)
    static var captionSize: CGFloat { NSFont.preferredFont(forTextStyle: .caption1).pointSize }
    static var smallSize: CGFloat { NSFont.preferredFont(forTextStyle: .caption2).pointSize }

    init(offscreen: CGRect? = nil, scale: CGFloat = 2) {
        self.offscreen = offscreen
        self.scale = scale
        let path = Self.pointerPath()
        root.masksToBounds = false
        body.anchorPoint = .zero
        body.bounds = .zero
        figure.bounds = CGRect(origin: .zero, size: Self.pointerSize)
        figure.anchorPoint = CGPoint(x: Self.tipPoint.x / Self.pointerSize.width,
                                     y: Self.tipPoint.y / Self.pointerSize.height)
        figure.position = .zero
        for layer in [tailEdge, tail, shadow, rim, pointer] {
            layer.frame = figure.bounds
            layer.lineJoin = .round
        }
        shadow.path = path
        rim.path = path
        rim.fillColor = nil
        rim.strokeColor = AgentCursorOverlay.deepBlue.withAlphaComponent(0.55).cgColor
        rim.lineWidth = 4.4
        pointer.path = path
        // The tail: a soft S of cmux blue with a white edge, behind the pointer.
        let rest = Self.tailPath(.rest)
        for (layer, width, color) in [(tailEdge, 5.6, NSColor.white), (tail, 3.0, AgentCursorOverlay.deepBlue)] {
            layer.path = rest
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = width
            layer.lineCap = .round
        }
        tailEdge.shadowColor = NSColor.black.cgColor
        tailEdge.shadowOpacity = 0.22
        tailEdge.shadowRadius = 2
        tailEdge.shadowOffset = CGSize(width: 0, height: -1)
        shadow.fillColor = NSColor.black.withAlphaComponent(0.001).cgColor
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.32
        shadow.shadowRadius = 3
        shadow.shadowOffset = CGSize(width: 0, height: -1.5)
        shadow.shadowPath = path
        pointer.fillColor = AgentCursorOverlay.blue.cgColor
        pointer.strokeColor = NSColor.white.cgColor
        pointer.lineWidth = 2
        // A soft light along the pointer's top edge: a gradient masked to the pointer's shape.
        shineMask.path = path
        shine.frame = CGRect(origin: .zero, size: Self.pointerSize)
        shine.colors = [NSColor.white.withAlphaComponent(0.5).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        shine.startPoint = CGPoint(x: 0.2, y: 1)
        shine.endPoint = CGPoint(x: 0.6, y: 0.4)
        shine.mask = shineMask
        pointer.addSublayer(shine)

        nameTag.backgroundColor = AgentCursorOverlay.blue.cgColor
        nameTag.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        nameTag.borderWidth = 1
        nameTag.shadowColor = NSColor.black.cgColor
        nameTag.shadowOpacity = 0.25
        nameTag.shadowRadius = 4
        nameTag.shadowOffset = CGSize(width: 0, height: -1)
        nameTag.anchorPoint = .zero
        nameTag.isHidden = true
        dot.backgroundColor = NSColor.white.cgColor
        dot.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
        dot.cornerRadius = 3
        Self.style(name, size: Self.captionSize, weight: .semibold, color: .white)
        nameTag.addSublayer(dot)
        nameTag.addSublayer(name)

        chipLayer.backgroundColor = NSColor(white: 0.08, alpha: 0.86).cgColor
        chipLayer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        chipLayer.borderWidth = 1
        chipLayer.anchorPoint = .zero
        chipLayer.isHidden = true
        chipLayer.shadowColor = NSColor.black.cgColor
        chipLayer.shadowOpacity = 0.22
        chipLayer.shadowRadius = 4
        chipLayer.shadowOffset = CGSize(width: 0, height: -1)

        figure.addSublayer(tailEdge)
        figure.addSublayer(tail)
        figure.addSublayer(shadow)
        figure.addSublayer(rim)
        figure.addSublayer(pointer)
        body.addSublayer(figure)
        body.addSublayer(nameTag)
        body.addSublayer(chipLayer)
        root.addSublayer(body)
    }

    private static func style(_ text: CATextLayer, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        text.font = NSFont.systemFont(ofSize: size, weight: weight)
        text.fontSize = size
        text.foregroundColor = color.cgColor
        text.alignmentMode = .left
        text.anchorPoint = .zero
        text.truncationMode = .end
    }

    /// The cursor's pointer: a chubby arrow with soft, rounded corners, tip at (2.5, 26) (y up).
    static func pointerPath() -> CGPath {
        let points = [
            CGPoint(x: 2.5, y: 26), CGPoint(x: 2.5, y: 6.5), CGPoint(x: 7.6, y: 11.2), CGPoint(x: 11.0, y: 3.4),
            CGPoint(x: 15.0, y: 5.2), CGPoint(x: 11.9, y: 12.8), CGPoint(x: 19.0, y: 12.8),
        ]
        let radii: [CGFloat] = [2.0, 2.4, 1.4, 1.6, 1.6, 1.4, 2.4]
        let path = CGMutablePath()
        let first = points[0], last = points[points.count - 1]
        path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
        for i in points.indices {
            path.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % points.count], radius: radii[i])
        }
        path.closeSubpath()
        var grid = CGAffineTransform(scaleX: k, y: k)
        return path.copy(using: &grid) ?? path
    }

    /// How the tail lies.
    enum TailPose: Equatable {
        /// At rest: a soft S below the pointer.
        case rest
        /// Trailing behind a move in direction (dx, dy) (unit vector, y up).
        case trailing(CGFloat, CGFloat)
        /// A wag to one side (+1 or -1).
        case wag(CGFloat)
    }

    /// The tail as a curve from the stem's end.
    static func tailPath(_ pose: TailPose) -> CGPath {
        let a = tailRoot
        let (c1, c2, end): (CGPoint, CGPoint, CGPoint)
        switch pose {
        case .rest:
            c1 = CGPoint(x: a.x + 0.5, y: a.y - 6)
            c2 = CGPoint(x: a.x + 8.5, y: a.y - 1.5)
            end = CGPoint(x: a.x + 9, y: a.y - 8)
        case .trailing(let dx, let dy):
            // Behind the move, with a little curl to the side.
            let (bx, by) = (-dx, -dy)
            let (px, py) = (-by, bx)
            c1 = CGPoint(x: a.x + bx * 4, y: a.y + by * 4)
            c2 = CGPoint(x: a.x + bx * 8 + px * 3, y: a.y + by * 8 + py * 3)
            end = CGPoint(x: a.x + bx * 13 - px * 1.5, y: a.y + by * 13 - py * 1.5)
        case .wag(let side):
            c1 = CGPoint(x: a.x + 0.5 + side * 2, y: a.y - 6)
            c2 = CGPoint(x: a.x + 8.5 + side * 3, y: a.y - 1.5 + side * 2)
            end = CGPoint(x: a.x + 9 + side * 4, y: a.y - 8 + side * 4)
        }
        let path = CGMutablePath()
        path.move(to: a)
        path.addCurve(to: end, control1: c1, control2: c2)
        var grid = CGAffineTransform(scaleX: k, y: k)
        return path.copy(using: &grid) ?? path
    }

    /// Animates the tail through `poses` (from rest, back to rest).
    private func swish(_ poses: [TailPose], keyTimes: [NSNumber], duration: CFTimeInterval) {
        // motion: allow called only from gated, animated motion (cursor switches, Reduce Motion, ui.animationSpeed).
        let swing = CAKeyframeAnimation(keyPath: "path")
        swing.values = poses.map { Self.tailPath($0) }
        swing.keyTimes = keyTimes
        swing.duration = duration
        swing.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(poses.count - 1, 1))
        tail.add(swing, forKey: "swish")
        tailEdge.add(swing, forKey: "swish")
    }

    /// A happy squish around the tip (the tip stays on its point) and a wag of the tail.
    private func squish(speed: Double) {
        // motion: allow called only from gated, animated motion (cursor switches, Reduce Motion, ui.animationSpeed).
        let squash = CAKeyframeAnimation(keyPath: "transform")
        squash.values = [CATransform3DIdentity, CATransform3DMakeScale(1.1, 0.84, 1), CATransform3DMakeScale(0.95, 1.06, 1),
                         CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        squash.keyTimes = [0, 0.3, 0.65, 1]
        squash.duration = 0.3 / max(speed, 0.25)
        figure.add(squash, forKey: "squish")
        swish([.rest, .wag(1), .wag(-1), .rest], keyTimes: [0, 0.3, 0.65, 1], duration: 0.42 / max(speed, 0.25))
    }

    /// The tail and pointer follow the alert color (amber, red), else cmux blue.
    private func tint(_ color: NSColor?) {
        pointer.fillColor = (color ?? AgentCursorOverlay.blue).cgColor
        let deep = color?.blended(withFraction: 0.25, of: .black) ?? AgentCursorOverlay.deepBlue
        tail.strokeColor = deep.cgColor
        rim.strokeColor = deep.withAlphaComponent(0.55).cgColor
    }

    /// Every layer under `layer` draws at `scale` (vector paths, text, shadows stay sharp).
    private func applyScale(to layer: CALayer) {
        layer.contentsScale = scale
        layer.rasterizationScale = scale
        layer.mask.map(applyScale(to:))
        for sub in layer.sublayers ?? [] { applyScale(to: sub) }
    }

    /// A new effect layer, at this screen's density, in `root` below the cursor body.
    private func effect<T: CALayer>(_ layer: T) -> T {
        applyScale(to: layer)
        root.insertSublayer(layer, below: body)
        return layer
    }

    private func local(_ point: CGPoint) -> CGPoint {
        guard let screenFrame else { return point }
        return CGPoint(x: point.x - screenFrame.minX, y: point.y - screenFrame.minY)
    }

    /// Shows one event (AppKit points through `geometry`).
    func apply(_ event: AgentCursorEvent, geometry: AgentCursorGeometry, animated: Bool, speed: Double) {
        let point = event.at.map { geometry.appKit($0) }
        switch event.kind {
        case .move:
            if let point { glide(to: point, animated: animated, speed: speed) }
        case .click:
            if let point { glide(to: point, animated: animated, speed: speed) }
            ripple(button: event.button, count: event.count, animated: animated, speed: speed)
            chip(.text(AgentCursorEvent.clickTitle(button: event.button, count: event.count)))
        case .typing:
            if let point { glide(to: point, animated: animated, speed: speed) }
            chip(.typing(AgentCursorEvent.caption(event.text)), animated: animated, speed: speed)
        case .keys:
            if let point { glide(to: point, animated: animated, speed: speed) }
            chip(.keys(AgentCursorEvent.keyCaps(event.text)))
            press(animated: animated, speed: speed)
        case .scroll:
            if let point { glide(to: point, animated: animated, speed: speed) }
            scrollMarks(event.scroll, animated: animated, speed: speed)
            chip(.text(ComputerUseText.t("computerUse.cursor.scroll", "Scroll") + " " + AgentCursorOverlay.arrow(event.scroll)))
        case .drag:
            if let start = event.from.map({ geometry.appKit($0) }), let point {
                drag(from: start, to: point, animated: animated, speed: speed)
            }
            chip(.text(ComputerUseText.t("computerUse.cursor.drag", "Drag")))
        case .look:
            if let point { glide(to: point, animated: animated, speed: speed) }
            if let rect = event.rect.map({ geometry.appKit($0) }) { frame(rect, animated: animated, speed: speed) }
            if animated { pulse(speed: speed) }
            chip(.text(ComputerUseText.t("computerUse.cursor.looking", "Looking")))
        case .paused:
            if let point { glide(to: point, animated: animated, speed: speed) }
            chip(.alert(ComputerUseText.t("computerUse.cursor.paused", "Paused \u{00B7} you\u{2019}re in control"), .paused))
        case .refused:
            chip(.alert(AgentCursorEvent.caption(event.text, limit: 40), .refused))
            shake(animated: animated, speed: speed)
        case .hide:
            break
        }
    }

    /// Draws the cursor's layers (their model state) into `context` (offscreen rendering).
    func draw(in context: CGContext) {
        root.render(in: context)
    }

    // MARK: Motion

    func glide(to point: CGPoint, animated: Bool, speed: Double) {
        let screens = NSScreen.screens
        let frame: CGRect
        if let offscreen {
            frame = offscreen
        } else {
            guard let hit = AgentCursorGeometry.screen(containing: point, in: screens.map(\.frame)) else { return }
            frame = hit
        }
        let movedScreen = screenFrame != frame
        if offscreen == nil {
            let panel = self.panel ?? Self.makePanel(root: root)
            self.panel = panel
            if movedScreen { panel.setFrame(frame, display: false) }
        }
        if movedScreen {
            screenFrame = frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.frame = CGRect(origin: .zero, size: frame.size)
            // Hand-made layers in a layer-hosting view are not scaled by AppKit: every layer draws
            // at the screen's pixel density (2 on Retina), not 1.
            if offscreen == nil { scale = screens.first { $0.frame == frame }?.backingScaleFactor ?? 2 }
            applyScale(to: root)
            CATransaction.commit()
        }
        let to = local(point)
        let from = tip.flatMap { movedScreen ? nil : local($0) }
        tip = point
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.position = to
        body.opacity = 1
        CATransaction.commit()
        if animated, let from, hypot(from.x - to.x, from.y - to.y) >= 1 {
            let plan = GlideMotion().plan(fromX: from.x, fromY: from.y, toX: to.x, toY: to.y, endHeading: 0)
            // motion: allow the worker's own gate: `animated` is the app's cursor switches and Reduce Motion (CursorMotionSettings), speed is ui.animationSpeed.
            let move = plan.positionAnimation(from: from)
            move.duration /= max(speed, 0.25)
            body.add(move, forKey: "glide")
            let length = max(hypot(to.x - from.x, to.y - from.y), 1)
            let way = TailPose.trailing((to.x - from.x) / length, (to.y - from.y) / length)
            // The tail streams behind the move, then flicks and settles with a happy wag.
            swish([.rest, way, way, .wag(1), .wag(-0.7), .wag(0.35), .rest],
                  keyTimes: [0, 0.1, 0.58, 0.72, 0.84, 0.93, 1],
                  duration: move.duration + 0.45 / max(speed, 0.25))
            comet(along: [from] + plan.samples.map { CGPoint(x: $0.x, y: $0.y) },
                  duration: move.duration, speed: speed)
        }
        body.removeAnimation(forKey: "fade")
        panel?.orderFrontRegardless()
    }

    /// A fading trail of the path the cursor just travelled, like a comet's tail: it follows
    /// the pointer (the same keyframes as its glide) and is longer the farther it goes (a
    /// quarter of the way, 24 to 320 points), thick and bright at the pointer and thinner and
    /// fainter behind it, then draws into the pointer once it arrives.
    func comet(along points: [CGPoint], duration: CFTimeInterval, speed: Double) {
        guard points.count >= 2 else { return }
        var cumulative: [CGFloat] = [0]
        for i in 1..<points.count {
            cumulative.append(cumulative[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        guard let total = cumulative.last, total >= 8 else { return }
        let path = CGMutablePath()
        path.addLines(between: points)
        let trailLength = min(max(total * 0.25, 24), 320)
        let catchUp = 0.32 / max(speed, 0.25)
        let whole = duration + catchUp
        // The head's progress along the path at each glide keyframe (the glide's keyTimes are even).
        let head = cumulative.map { Double($0 / total) }
        let headTimes = head.indices.map { Double($0) / Double(max(head.count - 1, 1)) * duration / whole }
        // Three strokes, newest thickest: together a trail that fades and thins behind the pointer.
        let strands: [(width: CGFloat, alpha: CGFloat, share: CGFloat)] = [(5, 0.42, 0.4), (3.4, 0.24, 0.72), (2, 0.12, 1)]
        for strand in strands {
            let trail = effect(CAShapeLayer())
            trail.path = path
            trail.fillColor = nil
            trail.strokeColor = AgentCursorOverlay.blue.withAlphaComponent(strand.alpha).cgColor
            trail.lineWidth = strand.width
            trail.lineCap = .round
            trail.lineJoin = .round
            trail.strokeStart = 1
            trail.strokeEnd = 1
            let lag = Double(trailLength * strand.share / total)
            // motion: allow called only from the gated, animated glide (cursor switches, Reduce Motion, ui.animationSpeed).
            let end = CAKeyframeAnimation(keyPath: "strokeEnd")
            end.values = head + [1]
            end.keyTimes = (headTimes + [1]).map { NSNumber(value: $0) }
            // motion: allow the same gated glide: the tail end follows the head, `lag` behind.
            let start = CAKeyframeAnimation(keyPath: "strokeStart")
            start.values = head.map { max($0 - lag, 0) } + [1]
            start.keyTimes = end.keyTimes
            // motion: allow the same gated glide.
            let group = CAAnimationGroup()
            group.animations = [end, start]
            group.duration = whole
            group.isRemovedOnCompletion = false
            group.fillMode = .forwards
            trail.add(group, forKey: "comet")
            Self.remove([trail], after: whole + 0.05)
        }
    }

    /// The trail as a still (for renders): the cursor moves to `point` and the last stretch of
    /// its straight path shows, fading, behind it.
    func stillTrail(to point: CGPoint) {
        guard let from = tip else { return }
        glide(to: point, animated: false, speed: 1)
        let a = local(from), b = local(point)
        let total = hypot(b.x - a.x, b.y - a.y)
        guard total >= 8 else { return }
        let trailLength = min(max(total * 0.25, 24), 320)
        let strands: [(width: CGFloat, alpha: CGFloat, share: CGFloat)] = [(5, 0.42, 0.4), (3.4, 0.24, 0.72), (2, 0.12, 1)]
        for strand in strands {
            let trail = effect(CAShapeLayer())
            let path = CGMutablePath()
            path.move(to: a)
            path.addLine(to: b)
            trail.path = path
            trail.fillColor = nil
            trail.strokeColor = AgentCursorOverlay.blue.withAlphaComponent(strand.alpha).cgColor
            trail.lineWidth = strand.width
            trail.lineCap = .round
            trail.strokeStart = max(1 - trailLength * strand.share / total, 0)
            trail.strokeEnd = 1
        }
        tail.path = Self.tailPath(.trailing((b.x - a.x) / total, (b.y - a.y) / total))
        tailEdge.path = tail.path
    }

    /// A small wag of the tail now and then while the cursor waits, so it feels alive.
    private func idleWag(speed: Double) {
        swish([.rest, .wag(0.8), .wag(-0.5), .wag(0.25), .rest], keyTimes: [0, 0.25, 0.55, 0.8, 1],
              duration: 0.7 / max(speed, 0.25))
    }

    /// Wags the tail every 1.4 s while the cursor is shown and nothing else moves it.
    func startIdleWag(animated: Bool, speed: Double) {
        idleTimer?.invalidate()
        guard animated else { return }
        // A bounded, repeating cosmetic wag; it stops with the cursor (close) and never synchronizes anything.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tail.animation(forKey: "swish") == nil else { return }
                self.idleWag(speed: speed)
            }
        }
    }

    /// A drag: a trail from `start` to `end` and the pointer gliding along it.
    func drag(from start: CGPoint, to end: CGPoint, animated: Bool, speed: Double) {
        glide(to: start, animated: animated, speed: speed)
        let a = local(start), b = local(end)
        let trail = effect(CAShapeLayer())
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        trail.path = path
        trail.strokeColor = AgentCursorOverlay.blue.withAlphaComponent(0.9).cgColor
        trail.lineWidth = 2.5
        trail.lineCap = .round
        trail.lineDashPattern = [1, 6]
        trail.fillColor = nil
        let ends = effect(CAShapeLayer())
        let dots = CGMutablePath()
        dots.addEllipse(in: CGRect(x: a.x - 4, y: a.y - 4, width: 8, height: 8))
        dots.addEllipse(in: CGRect(x: b.x - 5, y: b.y - 5, width: 10, height: 10))
        ends.path = dots
        ends.fillColor = AgentCursorOverlay.blue.cgColor
        ends.strokeColor = NSColor.white.cgColor
        ends.lineWidth = 1.5
        let lifetime = 1.1 / max(speed, 0.25)
        if animated {
            // motion: allow gated by `animated` (the app's cursor switches and Reduce Motion), speed from ui.animationSpeed.
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 0.35 / max(speed, 0.25)
            trail.add(draw, forKey: "draw")
            // motion: allow the same gated drag: the pointer follows the trail.
            let along = CABasicAnimation(keyPath: "position")
            along.fromValue = NSValue(point: a)
            along.toValue = NSValue(point: b)
            along.duration = draw.duration
            along.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            body.add(along, forKey: "glide")
            Self.fadeOut([trail, ends], after: lifetime * 0.6, duration: lifetime * 0.4)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.position = b
        CATransaction.commit()
        tip = end
        Self.remove([trail, ends], after: animated ? lifetime : 0.6)
    }

    // MARK: Effects

    /// One ripple per click, 90 ms apart; a right click's ring is dashed, a middle click's small.
    func ripple(button: String, count: Int, animated: Bool, speed: Double) {
        guard let tip else { return }
        let center = local(tip)
        let radius: CGFloat = button == "middle" ? 10 : 15
        for n in 0..<max(1, min(count, 3)) {
            let ring = effect(CAShapeLayer())
            // Each later click's ring is wider, so even a still frame shows how many there were.
            let r = radius + CGFloat(n) * 7
            ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
            ring.position = center
            ring.fillColor = AgentCursorOverlay.blue.withAlphaComponent(n == 0 ? 0.2 : 0).cgColor
            ring.strokeColor = AgentCursorOverlay.blue.cgColor
            ring.lineWidth = 2
            if button == "right" { ring.lineDashPattern = [4, 3] }
            let lifetime = 0.45 / max(speed, 0.25)
            if animated {
                // motion: allow gated by the worker's cursor switches and Reduce Motion (`animated`), speed from ui.animationSpeed.
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 0.25
                grow.toValue = 1.5
                // motion: allow the same gated ripple.
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                // motion: allow the same gated ripple.
                let group = CAAnimationGroup()
                group.animations = [grow, fade]
                group.duration = lifetime
                group.beginTime = CACurrentMediaTime() + Double(n) * 0.09 / max(speed, 0.25)
                group.fillMode = .both
                group.isRemovedOnCompletion = false
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ring.add(group, forKey: "ripple")
            }
            Self.remove([ring], after: animated ? lifetime + Double(n) * 0.09 / max(speed, 0.25) : 0.35)
        }
        press(animated: animated, speed: speed)
    }

    /// The pointer dips as it presses (a click or a key).
    /// A refused step: the pointer shakes no.
    func shake(animated: Bool, speed: Double) {
        guard animated else { return }
        // motion: allow called only when the cursor switches and Reduce Motion allow animation.
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -5, 5, -3, 3, 0]
        shake.duration = 0.32 / max(speed, 0.25)
        figure.add(shake, forKey: "shake")
    }

    func press(animated: Bool, speed: Double) {
        guard animated else { return }
        squish(speed: speed)
    }

    /// Three chevrons by the pointer, running in the scroll's direction.
    func scrollMarks(_ v: CGVector, animated: Bool, speed: Double) {
        guard let tip else { return }
        let origin = local(tip)
        let vertical = abs(v.dy) >= abs(v.dx)
        // Screen y is up in AppKit; scrolling down (dy > 0) runs the marks down.
        let sign: CGFloat = vertical ? (v.dy >= 0 ? -1 : 1) : (v.dx >= 0 ? 1 : -1)
        let lifetime = 0.6 / max(speed, 0.25)
        for n in 0..<3 {
            let mark = effect(CAShapeLayer())
            let path = CGMutablePath()
            if vertical {
                path.move(to: CGPoint(x: -5, y: -2.5 * sign))
                path.addLine(to: CGPoint(x: 0, y: 2.5 * sign))
                path.addLine(to: CGPoint(x: 5, y: -2.5 * sign))
            } else {
                path.move(to: CGPoint(x: -2.5 * sign, y: -5))
                path.addLine(to: CGPoint(x: 2.5 * sign, y: 0))
                path.addLine(to: CGPoint(x: -2.5 * sign, y: 5))
            }
            mark.path = path
            mark.strokeColor = AgentCursorOverlay.blue.cgColor
            mark.lineWidth = 2.25
            mark.lineCap = .round
            mark.lineJoin = .round
            mark.fillColor = nil
            // Left of the pointer for vertical scrolls, above it for horizontal ones: clear of the
            // name tag, which sits below and right of the tip.
            let step = CGFloat(n) * 8 * sign
            mark.position = vertical ? CGPoint(x: origin.x - 14, y: origin.y - 10 + step)
                                     : CGPoint(x: origin.x + 4 + step, y: origin.y + 12)
            if animated {
                // motion: allow gated by `animated` (cursor switches, Reduce Motion), speed from ui.animationSpeed.
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.values(from: 0, to: 1)
                fade.autoreverses = true
                fade.duration = lifetime / 2
                fade.beginTime = CACurrentMediaTime() + Double(n) * 0.07 / max(speed, 0.25)
                fade.fillMode = .both
                fade.isRemovedOnCompletion = false
                mark.add(fade, forKey: "run")
            }
            Self.remove([mark], after: animated ? lifetime + 0.25 : 0.5)
        }
    }

    /// Corner brackets around the window the agent looks at.
    func frame(_ rect: CGRect, animated: Bool, speed: Double) {
        guard let screenFrame else { return }
        let box = CGRect(x: rect.minX - screenFrame.minX, y: rect.minY - screenFrame.minY,
                         width: rect.width, height: rect.height).insetBy(dx: -3, dy: -3)
        let arm = min(22, box.width / 4, box.height / 4)
        let path = CGMutablePath()
        for (corner, dx, dy) in [(CGPoint(x: box.minX, y: box.minY), 1.0, 1.0), (CGPoint(x: box.maxX, y: box.minY), -1.0, 1.0),
                                 (CGPoint(x: box.minX, y: box.maxY), 1.0, -1.0), (CGPoint(x: box.maxX, y: box.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
        }
        let brackets = effect(CAShapeLayer())
        brackets.path = path
        brackets.strokeColor = AgentCursorOverlay.blue.cgColor
        brackets.lineWidth = 3
        brackets.lineCap = .round
        brackets.lineJoin = .round
        brackets.fillColor = nil
        brackets.shadowColor = AgentCursorOverlay.blue.cgColor
        brackets.shadowOpacity = 0.55
        brackets.shadowRadius = 5
        brackets.shadowOffset = .zero
        let lifetime = 0.7 / max(speed, 0.25)
        if animated {
            // motion: allow gated by `animated` (cursor switches, Reduce Motion), speed from ui.animationSpeed.
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.15, 0.6, 1]
            fade.duration = lifetime
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            brackets.add(fade, forKey: "look")
        }
        Self.remove([brackets], after: animated ? lifetime : 0.5)
    }

    /// The tip in AppKit screen points, once the cursor has been placed.
    var currentTip: CGPoint? { tip }

    /// Rings spread from the tip three times and the pointer squishes: "here I am".
    func spotlight(animated: Bool, speed: Double) {
        guard let tip else { return }
        panel?.orderFrontRegardless()
        let center = local(tip)
        let lifetime = 0.9 / max(speed, 0.25)
        for n in 0..<3 {
            let ring = effect(CAShapeLayer())
            let r: CGFloat = 46
            ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
            ring.position = center
            ring.fillColor = AgentCursorOverlay.blue.withAlphaComponent(n == 0 ? 0.14 : 0).cgColor
            ring.strokeColor = AgentCursorOverlay.blue.cgColor
            ring.lineWidth = 3
            if animated {
                // motion: allow gated by `animated` (cursor switches, Reduce Motion), speed from ui.animationSpeed.
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 0.15
                grow.toValue = 1
                // motion: allow the same gated spotlight.
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 0]
                fade.keyTimes = [0, 0.2, 1]
                // motion: allow the same gated spotlight.
                let group = CAAnimationGroup()
                group.animations = [grow, fade]
                group.duration = lifetime
                group.beginTime = CACurrentMediaTime() + Double(n) * 0.28 / max(speed, 0.25)
                group.fillMode = .both
                group.isRemovedOnCompletion = false
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ring.add(group, forKey: "spotlight")
            }
            Self.remove([ring], after: animated ? lifetime + Double(n) * 0.28 / max(speed, 0.25) : 1.2)
        }
        chip(.text(ComputerUseText.t("computerUse.cursor.here", "Here")))
        if animated { squish(speed: speed) }
    }

    func pulse(speed: Double) {
        // motion: allow called only when the cursor switches and Reduce Motion allow animation (AgentCursorOverlay.animates).
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1
        pulse.toValue = 1.18
        pulse.autoreverses = true
        pulse.duration = 0.16 / max(speed, 0.25)
        figure.add(pulse, forKey: "pulse")
    }

    // MARK: Name and chip

    /// Shows `content` in the chip under the name for a moment; typing shows a blinking caret.
    func chip(_ content: CursorChip, animated: Bool = false, speed: Double = 1) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chipContent.forEach { $0.removeFromSuperlayer() }
        chipContent = []
        let padX: CGFloat = 8, padY: CGFloat = 4, gap: CGFloat = 4
        var x = padX
        var height: CGFloat = 0
        let alert: CursorAlert? = if case .alert(_, let kind) = content { kind } else { nil }
        chipLayer.backgroundColor = alert?.color.cgColor ?? NSColor(white: 0.08, alpha: 0.86).cgColor
        tint(alert?.color)
        nameTag.backgroundColor = alert?.color.cgColor ?? AgentCursorOverlay.blue.cgColor
        name.foregroundColor = (alert?.textColor ?? .white).cgColor
        dot.backgroundColor = (alert?.textColor ?? .white).cgColor
        switch content {
        case .alert(let text, let kind):
            let label = CATextLayer()
            Self.style(label, size: Self.captionSize, weight: .semibold, color: kind.textColor)
            label.string = text
            let size = Self.size(of: text, size: Self.captionSize, weight: .semibold)
            label.frame = CGRect(x: x, y: padY, width: size.width, height: size.height)
            chipLayer.addSublayer(label)
            chipContent.append(label)
            x += size.width
            height = size.height
        case .text(let text), .typing(let text):
            let label = CATextLayer()
            Self.style(label, size: Self.captionSize, weight: .medium, color: .white)
            label.string = text
            let size = Self.size(of: text, size: Self.captionSize, weight: .medium)
            label.frame = CGRect(x: x, y: padY, width: size.width, height: size.height)
            chipLayer.addSublayer(label)
            chipContent.append(label)
            x += size.width
            height = size.height
            if case .typing = content {
                let caret = CALayer()
                caret.backgroundColor = AgentCursorOverlay.blue.cgColor
                caret.frame = CGRect(x: x + 2, y: padY + 1, width: 2, height: size.height - 2)
                caret.cornerRadius = 1
                chipLayer.addSublayer(caret)
                chipContent.append(caret)
                x += 4
                if animated {
                    // motion: allow gated by `animated` (cursor switches, Reduce Motion), speed from ui.animationSpeed.
                    let blink = CABasicAnimation(keyPath: "opacity")
                    blink.fromValue = 1
                    blink.toValue = 0.15
                    blink.autoreverses = true
                    blink.repeatCount = 4
                    blink.duration = 0.4 / max(speed, 0.25)
                    caret.add(blink, forKey: "blink")
                }
            }
        case .keys(let caps):
            for cap in caps {
                let key = CALayer()
                key.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
                key.cornerRadius = 4
                key.borderColor = NSColor(white: 0.7, alpha: 1).cgColor
                key.borderWidth = 0.5
                key.shadowColor = NSColor.black.cgColor
                key.shadowOpacity = 0.35
                key.shadowRadius = 0
                key.shadowOffset = CGSize(width: 0, height: -1)
                let text = CATextLayer()
                Self.style(text, size: Self.captionSize, weight: .semibold, color: NSColor(white: 0.12, alpha: 1))
                text.alignmentMode = .center
                text.string = cap
                let size = Self.size(of: cap, size: Self.captionSize, weight: .semibold)
                let width = max(size.width + 10, size.height + 6)
                key.frame = CGRect(x: x, y: padY, width: width, height: size.height + 4)
                text.frame = CGRect(x: 0, y: 2, width: width, height: size.height)
                key.addSublayer(text)
                chipLayer.addSublayer(key)
                chipContent.append(key)
                x += width + gap
                height = max(height, size.height + 4)
            }
            x -= gap
        }
        let chipSize = CGSize(width: x + padX, height: height + padY * 2)
        chipLayer.bounds = CGRect(origin: .zero, size: chipSize)
        chipLayer.cornerRadius = chipSize.height / 2
        chipLayer.isHidden = false
        chipLayer.opacity = 1
        applyScale(to: chipLayer)
        layoutName()
        CATransaction.commit()
        chipTimer?.invalidate()
        // The chip's bounded display time; a one-shot hide, replaced by the next step.
        // Paused holds for the takeover wait (cursor.rs TAKEOVER_WAIT); the next step replaces it.
        let hold: TimeInterval = switch content {
        case .typing: 2.4
        case .alert(_, .paused): 15
        case .alert(_, .refused): 2.4
        default: 1.6
        }
        chipTimer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.chipLayer.isHidden = true
                self.tint(nil)
                self.nameTag.backgroundColor = AgentCursorOverlay.blue.cgColor
                self.name.foregroundColor = NSColor.white.cgColor
                self.dot.backgroundColor = NSColor.white.cgColor
                CATransaction.commit()
            }
        }
    }

    /// The name tag right of and below the tip, the chip under it.
    private func layoutName() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        name.string = label
        nameTag.isHidden = label.isEmpty
        var size = Self.size(of: label, size: Self.captionSize, weight: .semibold)
        // A long name ends in an ellipsis instead of running off the screen.
        size.width = min(size.width, Self.maxNameWidth)
        let padX: CGFloat = 8, padY: CGFloat = 3
        let dotSpace: CGFloat = 12
        let tagSize = CGSize(width: size.width + padX * 2 + dotSpace, height: size.height + padY * 2)
        nameTag.bounds = CGRect(origin: .zero, size: tagSize)
        nameTag.cornerRadius = tagSize.height / 2
        dot.position = CGPoint(x: padX + 3, y: tagSize.height / 2)
        name.frame = CGRect(x: padX + dotSpace, y: padY, width: size.width, height: size.height)
        // Below and right of the tip (AppKit y up): clear of the pointer's body.
        // Right of the tail's tip, so the tail shows.
        nameTag.position = CGPoint(x: 30, y: -30 - tagSize.height)
        chipLayer.position = CGPoint(x: 30, y: nameTag.position.y - 5 - chipLayer.bounds.height)
        CATransaction.commit()
    }

    private static func size(of text: String, size: CGFloat, weight: NSFont.Weight) -> CGSize {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }

    // MARK: Lifetime

    func armIdleHide(after seconds: TimeInterval, _ hide: @escaping @MainActor () -> Void) {
        hideTimer?.invalidate()
        // cursor.rs IDLE_HIDE: one-shot, replaced by every event.
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { hide() }
        }
    }

    func close(animated: Bool, speed: Double) {
        hideTimer?.invalidate()
        hideTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        chipTimer?.invalidate()
        chipTimer = nil
        // A cursor shown again later makes a new panel and sizes it to its screen.
        screenFrame = nil
        guard let panel else { return }
        self.panel = nil
        if animated {
            // motion: allow gated by `animated` (cursor switches, Reduce Motion), speed from ui.animationSpeed.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.25 / max(speed, 0.25)
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            body.add(fade, forKey: "fade")
            // The fade's bounded display time; a one-shot order-out.
            nonisolated(unsafe) let fading = panel // only touched on the main run loop below
            Timer.scheduledTimer(withTimeInterval: fade.duration, repeats: false) { _ in
                MainActor.assumeIsolated { fading.orderOut(nil) }
            }
        } else {
            panel.orderOut(nil)
        }
    }

    /// Removes effect layers after their bounded display time (a one-shot, not a synchronization).
    private static func remove(_ layers: [CALayer], after seconds: TimeInterval) {
        nonisolated(unsafe) let shown = layers // only touched on the main run loop below
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { shown.forEach { $0.removeFromSuperlayer() } }
        }
    }

    private static func fadeOut(_ layers: [CALayer], after delay: TimeInterval, duration: TimeInterval) {
        for layer in layers {
            // motion: allow called only from gated, animated effects.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.beginTime = CACurrentMediaTime() + delay
            fade.duration = duration
            fade.fillMode = .both
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: "fadeOut")
        }
    }

    static func makePanel(root: CALayer) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        // Visible to the person's screen recordings and sharing; agents' captures leave it out
        // through ScreenCapture's own-process filter, not through sharingType.
        panel.sharingType = .readOnly
        // A layer-hosting view: the layer first, then wantsLayer.
        let view = NSView()
        view.layer = root
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }
}

private extension CABasicAnimation {
    func values(from: Double, to: Double) {
        fromValue = from
        toValue = to
    }
}
