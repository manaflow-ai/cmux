import AppKit

/// cmux: the layers and Core Animation of each ``CmuxSidebarAvatarMotionStyle`` (``SidebarAvatarMotion``
/// decides which look and when). A look lives on the avatar layer and two named sublayers of it, a ring
/// on its edge and a glint masked to the avatar's own picture, so the vendored row needs no new layer.
/// Nothing here translates the avatar: the only transforms are a scale or a turn about its centre.
///
/// motion: allow every loop and cue here is added only while ``SidebarAvatarMotion/mayRun(in:)`` holds
/// (Reduce Motion, calm mode, speed off and Home's switch through the host's gate, the app active and the
/// window visible), and ``clear(_:keepCue:)`` removes them when it stops holding or the row is pooled.
@MainActor
struct SidebarAvatarLooks {
    static let ringName = "cmux.avatarRing"
    static let glintName = "cmux.avatarGlint"

    /// Working's arc: one turn, linear (`motion-and-polish`: a loop, not a transition).
    static let arcPeriod: CFTimeInterval = 1.6
    /// Idle's glint: one sweep, then rest until the next (a pet's blink).
    static let idleGlintPeriod: CFTimeInterval = 7
    static let glintSweep: CFTimeInterval = 0.7
    /// Glow's working glint: sweeps back to back, with a short rest.
    static let workingGlintPeriod: CFTimeInterval = 1.8
    /// Tilt: the idle glance and the working rock.
    static let idleTiltPeriod: CFTimeInterval = 6
    static let workingTiltPeriod: CFTimeInterval = 1.4
    /// A cue's whole length (`motion-and-polish`: nothing that is not a loop runs past 240 ms).
    static let cueDuration: CFTimeInterval = 0.24

    // MARK: Layers

    /// The ring on the avatar's edge (created on first use).
    static func ring(_ avatar: CALayer) -> CAShapeLayer {
        if let ring = avatar.sublayers?.first(where: { $0.name == ringName }) as? CAShapeLayer { return ring }
        let ring = CAShapeLayer()
        ring.name = ringName
        ring.actions = quiet
        ring.fillColor = nil
        ring.lineCap = .round
        avatar.addSublayer(ring)
        return ring
    }

    /// The glint: a soft band of light, clipped to the avatar picture's own shape (a mascot with room
    /// around it glints only where it is drawn).
    static func glint(_ avatar: CALayer) -> CALayer {
        if let glint = avatar.sublayers?.first(where: { $0.name == glintName }) { return glint }
        let glint = CALayer()
        glint.name = glintName
        glint.actions = quiet
        let mask = CALayer()
        mask.actions = quiet
        glint.mask = mask
        let band = CAGradientLayer()
        band.actions = quiet
        band.colors = [NSColor(white: 1, alpha: 0).cgColor, NSColor(white: 1, alpha: 0.55).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        glint.addSublayer(band)
        avatar.addSublayer(glint)
        return glint
    }

    /// Keeps the ring and glint on the avatar's bounds and picture (after a layout or a new picture).
    static func fit(_ avatar: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let bounds = avatar.bounds
        if let ring = avatar.sublayers?.first(where: { $0.name == ringName }) as? CAShapeLayer {
            ring.frame = bounds
            let width = ringWidth(bounds)
            ring.lineWidth = width
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: width / 2, dy: width / 2), transform: nil)
        }
        if let glint = avatar.sublayers?.first(where: { $0.name == glintName }) {
            glint.frame = bounds
            glint.mask?.frame = bounds
            glint.mask?.contents = avatar.contents
            glint.mask?.contentsGravity = avatar.contentsGravity
            if let band = glint.sublayers?.first {
                band.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.45, height: bounds.height * 1.6)
                band.position = CGPoint(x: -bounds.width, y: bounds.midY)
                band.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 9))
            }
        }
    }

    static func ringWidth(_ bounds: CGRect) -> CGFloat { max(1.5, (bounds.width * 0.05).rounded(.toNearestOrAwayFromZero)) }

    /// No implicit animation on any property a look sets.
    static let quiet: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(),
                                            "strokeEnd": NSNull(), "strokeColor": NSNull(), "opacity": NSNull(), "hidden": NSNull(),
                                            "contents": NSNull(), "lineWidth": NSNull(), "transform": NSNull(), "mask": NSNull()]

    // MARK: Looks

    /// Whether `look` should have a loop on `avatar` and none is there (removed by the system or by hand).
    static func isMissing(_ look: SidebarAvatarMotion.Look, on avatar: CALayer) -> Bool {
        look.moving && loops(look) && !SidebarAvatarMotion.isLooping(avatar)
    }

    /// Whether `look` has a loop: Ring and Glow loop at idle and working, Tilt at idle and working.
    static func loops(_ look: SidebarAvatarMotion.Look) -> Bool {
        switch (look.style, look.mode) {
        case (.still, _): false
        case (.glow, .idle): false
        case (_, .idle), (_, .working): true
        case (_, .waiting), (_, .failed): false
        }
    }

    /// Removes the look: every loop, the ring and glint, the glow; the cue too unless `keepCue`.
    static func clear(_ avatar: CALayer, keepCue: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        avatar.removeAnimation(forKey: SidebarAvatarMotion.animationKey)
        if !keepCue { avatar.removeAnimation(forKey: SidebarAvatarMotion.cueKey) }
        avatar.sublayers?.filter { $0.name == ringName || $0.name == glintName }.forEach { $0.removeFromSuperlayer() }
        avatar.shadowOpacity = 0
    }

    /// Draws `look` on a cleared avatar: its still parts always, its loop while `look.moving`.
    static func show(_ look: SidebarAvatarMotion.Look, on avatar: CALayer, seed: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let phase = SidebarAvatarMotion.phase(seed)
        let accent = NSColor.controlAccentColor.cgColor
        let red = NSColor.systemRed.cgColor
        switch (look.style, look.mode) {
        case (.still, _):
            return
        case (.glow, .idle):
            return
        case (.glow, .working):
            glow(avatar, color: accent, opacity: 0.35)
            if look.moving { sweep(avatar, period: workingGlintPeriod, phase: phase) }
        case (.glow, .waiting):
            glow(avatar, color: accent, opacity: 0.5)
        case (.glow, .failed):
            glow(avatar, color: red, opacity: 0.55)
        case (.ring, .idle):
            if look.moving { sweep(avatar, period: idleGlintPeriod, phase: phase) }
        case (.tilt, .idle):
            if look.moving { tilt(avatar, period: idleTiltPeriod, degrees: 3, glance: true, phase: phase) }
        case (.ring, .working):
            arc(avatar, color: accent, moving: look.moving, phase: phase)
        case (.tilt, .working):
            if look.moving { tilt(avatar, period: workingTiltPeriod, degrees: 4, glance: false, phase: phase) }
        case (.ring, .waiting), (.tilt, .waiting):
            still(avatar, color: accent, opacity: 0.6)
        case (.ring, .failed), (.tilt, .failed):
            still(avatar, color: red, opacity: 0.8)
        }
        fit(avatar)
    }

    /// A still ring all the way round (waiting, failed: static indicators that stay under Reduce Motion).
    static func still(_ avatar: CALayer, color: CGColor, opacity: Float) {
        let ring = ring(avatar)
        ring.strokeColor = color
        ring.strokeStart = 0
        ring.strokeEnd = 1
        ring.opacity = opacity
    }

    /// Working's arc: a quarter of the ring turning round the edge. Under Reduce Motion it stands, a
    /// still quarter, so the state still reads.
    static func arc(_ avatar: CALayer, color: CGColor, moving: Bool, phase: Double) {
        let ring = ring(avatar)
        ring.strokeColor = color
        ring.strokeStart = 0
        ring.strokeEnd = 0.28
        ring.opacity = 0.85
        guard moving else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi  // clockwise on a flipped layer and AppKit's alike reads as "running"
        turn.duration = arcPeriod
        turn.repeatCount = .infinity
        turn.timeOffset = phase * arcPeriod
        turn.isRemovedOnCompletion = false
        ring.add(turn, forKey: SidebarAvatarMotion.animationKey)
    }

    /// A glow behind the avatar's own shape (its shadow, no offset).
    static func glow(_ avatar: CALayer, color: CGColor, opacity: Float) {
        avatar.shadowColor = color
        avatar.shadowOffset = .zero
        avatar.shadowRadius = max(2, avatar.bounds.width * 0.1)
        avatar.shadowOpacity = opacity
    }

    /// A glint sweeping across the face once per `period`, then resting off the face.
    static func sweep(_ avatar: CALayer, period: CFTimeInterval, phase: Double) {
        let glint = glint(avatar)
        fit(avatar)
        guard let band = glint.sublayers?.first else { return }
        let width = max(avatar.bounds.width, 1)
        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.values = [-width * 0.5, width * 1.5, width * 1.5]
        move.keyTimes = [0, NSNumber(value: min(1, glintSweep / period)), 1]
        move.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
        move.duration = period
        move.repeatCount = .infinity
        move.timeOffset = phase * period
        move.isRemovedOnCompletion = false
        band.add(move, forKey: SidebarAvatarMotion.animationKey)
    }

    /// The avatar turns a few degrees about its centre: a glance (once, then rest) or a slow rock.
    static func tilt(_ avatar: CALayer, period: CFTimeInterval, degrees: Double, glance: Bool, phase: Double) {
        let angle = degrees * .pi / 180
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        if glance {
            // Turn, hold a beat, turn back, then rest for the rest of the period.
            turn.values = [0, angle, angle, 0, 0]
            turn.keyTimes = [0, 0.05, 0.12, 0.17, 1].map { NSNumber(value: $0) }
        } else {
            turn.values = [0, angle, 0, -angle, 0]
            turn.keyTimes = [0, 0.25, 0.5, 0.75, 1].map { NSNumber(value: $0) }
        }
        turn.calculationMode = .cubic
        turn.duration = period
        turn.repeatCount = .infinity
        turn.timeOffset = phase * period
        turn.isRemovedOnCompletion = false
        avatar.add(turn, forKey: SidebarAvatarMotion.animationKey)
    }

    // MARK: Cues

    /// The one-shot of a change from `from` to `to`, if it has one: a turn ending (working to idle or
    /// waiting) pops the avatar 4 %; a failure shakes it a few degrees about its centre; a reply waiting
    /// with no turn seen fades its ring in (Glow has no ring: nothing). At most ``cueDuration``.
    enum Cue: Equatable {
        case pop
        case shake
        case ringIn
    }

    static func cue(from: SidebarAvatarMotion.Mode, to: SidebarAvatarMotion.Mode) -> Cue? {
        switch (from, to) {
        case (_, .failed): .shake
        case (.working, .idle), (.working, .waiting): .pop
        case (_, .waiting): .ringIn
        default: nil
        }
    }

    static func cue(_ avatar: CALayer, style: CmuxSidebarAvatarMotionStyle, from: SidebarAvatarMotion.Mode, to: SidebarAvatarMotion.Mode) {
        guard style != .still, let cue = cue(from: from, to: to) else { return }
        let animation: CAAnimation
        var target = avatar
        switch cue {
        case .pop:
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [1, 1.04, 1]
            pop.keyTimes = [0, 0.4, 1]
            pop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            animation = pop
        case .shake:
            let r = Double.pi / 180
            let shake = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            shake.values = [0, 6 * r, -5 * r, 3 * r, 0]
            shake.keyTimes = [0, 0.2, 0.5, 0.8, 1]
            animation = shake
        case .ringIn:
            // The state's ring (just drawn) fades in; the avatar itself stays as it is.
            guard let ring = avatar.sublayers?.first(where: { $0.name == ringName }) else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animation = fade
            target = ring
        }
        animation.duration = cueDuration
        animation.isRemovedOnCompletion = true
        target.add(animation, forKey: SidebarAvatarMotion.cueKey)
    }
}
