// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CmuxAgentCursor
import QuartzCore

/// The agent cursor (cursor.rs): one click-through, non-activating panel per agent session, on
/// every Space and over full-screen apps, showing a cmux blue pointer with the agent's name. It
/// glides to each point the agent acts on, ripples on a click, captions what it types, pulses
/// when it looks, and hides after `idleHide` without events or on `hide`. The real pointer never
/// moves. The panels are left out of every capture (`sharingType = .none` and ScreenCapture's
/// own-process filter), so agents never see the cursor in their screenshots.
///
/// Motion follows the app's cursor switches (``CursorMotionSettings``, from the host's config)
/// and macOS Reduce Motion: with animation off every change applies at once and nothing pulses.
@MainActor
final class AgentCursorOverlay {
    /// cursor.rs `IDLE_HIDE`.
    static let idleHide: TimeInterval = 4
    /// #0A84FF, cursor.rs `CMUX_BLUE`.
    static let blue = NSColor(srgbRed: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255, alpha: 1)

    var motion = CursorMotionSettings()
    /// `showCursor` off: events are ignored and every cursor hides.
    var enabled = true {
        didSet { if !enabled { hideAll() } }
    }
    private var cursors: [String: SessionCursor] = [:]
    private let reduceMotion: () -> Bool

    init(reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.reduceMotion = reduceMotion
    }

    private var animates: Bool { motion.animates(reduceMotion: reduceMotion()) }

    func show(_ event: AgentCursorEvent) {
        if event.kind == .hide {
            cursors.removeValue(forKey: event.session)?.close()
            return
        }
        guard enabled else { return }
        let cursor = cursors[event.session] ?? SessionCursor()
        cursors[event.session] = cursor
        cursor.label = event.label
        let geometry = AgentCursorGeometry(primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
        let point = event.at.map { geometry.appKit($0) }
        switch event.kind {
        case .move:
            if let point { cursor.glide(to: point, animated: animates, speed: motion.speed) }
        case .click:
            if let point { cursor.glide(to: point, animated: animates, speed: motion.speed) }
            cursor.ripple(animated: animates, speed: motion.speed)
        case .typing:
            if let point { cursor.glide(to: point, animated: animates, speed: motion.speed) }
            cursor.caption(AgentCursorEvent.caption(event.text))
        case .look:
            if let point { cursor.glide(to: point, animated: animates, speed: motion.speed) }
            if animates { cursor.pulse(speed: motion.speed) }
        case .hide:
            break
        }
        cursor.armIdleHide(after: Self.idleHide) { [weak self] in
            guard let self, self.cursors[event.session] === cursor else { return }
            self.cursors.removeValue(forKey: event.session)?.close()
        }
    }

    func hideAll() {
        for cursor in cursors.values { cursor.close() }
        cursors.removeAll()
    }

    var sessionCount: Int { cursors.count }
}

/// One session's cursor: its panel (on the screen it is on) and layers.
@MainActor
private final class SessionCursor {
    private var panel: NSPanel?
    private let root = CALayer()
    private let arrow = CAShapeLayer()
    private let name = CATextLayer()
    private let typing = CATextLayer()
    /// The tip, in AppKit screen points.
    private var tip: CGPoint?
    private var hideTimer: Timer?
    var label = "" {
        didSet { if label != oldValue { layoutName() } }
    }

    static let arrowSize = CGSize(width: 15, height: 22)

    init() {
        arrow.path = Self.arrowPath()
        arrow.fillColor = AgentCursorOverlay.blue.cgColor
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = 1.5
        arrow.lineJoin = .round
        arrow.shadowColor = NSColor.black.cgColor
        arrow.shadowOpacity = 0.35
        arrow.shadowRadius = 2.5
        arrow.shadowOffset = CGSize(width: 0, height: -1)
        arrow.bounds = CGRect(origin: .zero, size: Self.arrowSize)
        arrow.anchorPoint = CGPoint(x: 1.5 / Self.arrowSize.width, y: 20.5 / Self.arrowSize.height)
        for text in [name, typing] {
            text.font = NSFont.systemFont(ofSize: 0, weight: .semibold)
            text.fontSize = NSFont.preferredFont(forTextStyle: .caption1).pointSize
            text.alignmentMode = .center
            text.cornerRadius = 6
            text.masksToBounds = true
            text.isHidden = true
        }
        name.backgroundColor = AgentCursorOverlay.blue.cgColor
        name.foregroundColor = NSColor.white.cgColor
        typing.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        typing.foregroundColor = NSColor.white.cgColor
        root.addSublayer(arrow)
        root.addSublayer(name)
        root.addSublayer(typing)
    }

    /// A pointer arrow, tip at the top left (y up).
    static func arrowPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1.5, y: 20.5))
        path.addLine(to: CGPoint(x: 1.5, y: 3.5))
        path.addLine(to: CGPoint(x: 5.6, y: 7.6))
        path.addLine(to: CGPoint(x: 8.6, y: 1.2))
        path.addLine(to: CGPoint(x: 11.2, y: 2.4))
        path.addLine(to: CGPoint(x: 8.3, y: 8.6))
        path.addLine(to: CGPoint(x: 13.8, y: 8.6))
        path.closeSubpath()
        return path
    }

    func glide(to point: CGPoint, animated: Bool, speed: Double) {
        let screens = NSScreen.screens.map(\.frame)
        guard let screen = AgentCursorGeometry.screen(containing: point, in: screens) else { return }
        let panel = self.panel ?? Self.makePanel(root: root)
        self.panel = panel
        let movedScreen = panel.frame != screen
        if movedScreen {
            panel.setFrame(screen, display: false)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.frame = CGRect(origin: .zero, size: screen.size)
            CATransaction.commit()
        }
        let local = CGPoint(x: point.x - screen.minX, y: point.y - screen.minY)
        let from = tip.flatMap { movedScreen ? nil : CGPoint(x: $0.x - screen.minX, y: $0.y - screen.minY) }
        tip = point
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.position = local
        layoutName()
        CATransaction.commit()
        if animated, let from, hypot(from.x - local.x, from.y - local.y) >= 1 {
            let plan = GlideMotion().plan(fromX: from.x, fromY: from.y, toX: local.x, toY: local.y, endHeading: 0)
            // motion: allow the worker's own gate: `animated` is the app's cursor switches and Reduce Motion (CursorMotionSettings), speed is ui.animationSpeed.
            let move = plan.positionAnimation(from: from)
            move.duration /= max(speed, 0.25)
            arrow.add(move, forKey: "glide")
            for text in [name, typing] {
                // motion: allow the same gated glide, offset to the label's place.
                let follow = plan.positionAnimation(from: from)
                follow.duration = move.duration
                follow.values = follow.values?.compactMap { ($0 as? NSValue)?.pointValue }
                    .map { NSValue(point: CGPoint(x: $0.x + (text.position.x - local.x), y: $0.y + (text.position.y - local.y))) }
                text.add(follow, forKey: "glide")
            }
        }
        panel.orderFrontRegardless()
    }

    func ripple(animated: Bool, speed: Double) {
        guard let panel, let tip else { return }
        let ring = CAShapeLayer()
        let radius: CGFloat = 14
        ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ring.fillColor = AgentCursorOverlay.blue.withAlphaComponent(0.18).cgColor
        ring.strokeColor = AgentCursorOverlay.blue.cgColor
        ring.lineWidth = 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.position = CGPoint(x: tip.x - panel.frame.minX, y: tip.y - panel.frame.minY)
        root.insertSublayer(ring, below: arrow)
        CATransaction.commit()
        let lifetime = 0.35 / max(speed, 0.25)
        if animated {
            // motion: allow gated by the worker's cursor switches and Reduce Motion (`animated`), speed from ui.animationSpeed.
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.3
            grow.toValue = 1.4
            // motion: allow the same gated ripple.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            // motion: allow the same gated ripple.
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = lifetime
            group.isRemovedOnCompletion = false
            group.fillMode = .forwards
            ring.add(group, forKey: "ripple")
        }
        // The ring's bounded display time (animated or not); a one-shot removal, not a synchronization.
        Timer.scheduledTimer(withTimeInterval: animated ? lifetime : 0.3, repeats: false) { _ in
            MainActor.assumeIsolated { ring.removeFromSuperlayer() }
        }
    }

    func caption(_ text: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        typing.string = text
        typing.isHidden = text.isEmpty
        layoutName()
        CATransaction.commit()
    }

    func pulse(speed: Double) {
        // motion: allow called only when the cursor switches and Reduce Motion allow animation (AgentCursorOverlay.animates).
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1
        pulse.toValue = 1.25
        pulse.autoreverses = true
        pulse.duration = 0.18 / max(speed, 0.25)
        arrow.add(pulse, forKey: "pulse")
    }

    func armIdleHide(after seconds: TimeInterval, _ hide: @escaping @MainActor () -> Void) {
        hideTimer?.invalidate()
        // cursor.rs IDLE_HIDE: one-shot, replaced by every event.
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { hide() }
        }
    }

    func close() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// The name pill right of the arrow, the typing caption under it.
    private func layoutName() {
        let base = arrow.position
        let padding: CGFloat = 6
        name.string = label
        name.isHidden = label.isEmpty
        let nameSize = Self.size(of: label, layer: name)
        name.bounds = CGRect(x: 0, y: 0, width: nameSize.width + padding * 2, height: nameSize.height + 4)
        name.position = CGPoint(x: base.x + 14 + name.bounds.width / 2, y: base.y - 22 - name.bounds.height / 2)
        let text = typing.string as? String ?? ""
        let textSize = Self.size(of: text, layer: typing)
        typing.bounds = CGRect(x: 0, y: 0, width: textSize.width + padding * 2, height: textSize.height + 4)
        typing.position = CGPoint(x: base.x + 14 + typing.bounds.width / 2,
                                  y: name.position.y - name.bounds.height / 2 - 4 - typing.bounds.height / 2)
    }

    private static func size(of text: String, layer: CATextLayer) -> CGSize {
        let font = NSFont.systemFont(ofSize: layer.fontSize, weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
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
        // Never in a screen capture: an agent must not see (or click) its own cursor.
        panel.sharingType = .none
        // A layer-hosting view: the layer first, then wantsLayer.
        let view = NSView()
        view.layer = root
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }
}
