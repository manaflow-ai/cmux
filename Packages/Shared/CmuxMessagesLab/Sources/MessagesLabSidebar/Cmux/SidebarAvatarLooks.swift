import AppKit

/// cmux: the layers and Core Animation of each ``CmuxSidebarAvatarMotionStyle`` (``SidebarAvatarMotion``
/// decides which look and when). A look lives on the avatar layer and three named sublayers of it, a ring
/// on its edge, a glint masked to the avatar's own picture and done's check badge on its lower trailing
/// edge, so the vendored row needs no new layer.
/// Nothing here translates the avatar: the only transforms are a scale or a turn about its centre.
///
/// motion: allow every loop and cue here is added only while ``SidebarAvatarMotion/mayRun(in:)`` holds
/// (Reduce Motion, calm mode, speed off and Home's switch through the host's gate, the app active and the
/// window visible), and ``clear(_:keepCue:)`` removes them when it stops holding or the row is pooled.
@MainActor
struct SidebarAvatarLooks {
    static let ringName = "cmux.avatarRing"
    static let glintName = "cmux.avatarGlint"
    static let badgeName = "cmux.avatarBadge"

    /// Thinking's arc: one turn, linear (`motion-and-polish`: a loop, not a transition).
    static let arcPeriod: CFTimeInterval = 1.6
    /// Tool running's ring of dots: one turn, linear, slower than thinking's arc so the two read apart.
    static let dotsPeriod: CFTimeInterval = 3.2
    /// Tool running's dots round the edge.
    static let dotCount = 12
    /// One glint's sweep across the face: Glow's working loop (with a rest), and Ring's cue.
    static let glintSweep: CFTimeInterval = 0.7
    /// Glow's thinking glint: sweeps back to back, with a short rest.
    static let workingGlintPeriod: CFTimeInterval = 1.8
    /// Tilt's thinking rock.
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

    /// Done's badge: a green disc with a white check, on the avatar's lower trailing edge (the Codex and
    /// Chief-card "done" mark, `cmux/live/chief-pill-proportions`). Drawn once; nothing loops on it.
    static func badge(_ avatar: CALayer) -> CAShapeLayer {
        if let badge = avatar.sublayers?.first(where: { $0.name == badgeName }) as? CAShapeLayer { return badge }
        let badge = CAShapeLayer()
        badge.name = badgeName
        badge.actions = quiet
        badge.fillColor = NSColor.systemGreen.cgColor
        let check = CAShapeLayer()
        check.actions = quiet
        check.fillColor = nil
        check.strokeColor = NSColor.white.cgColor
        check.lineCap = .round
        check.lineJoin = .round
        badge.addSublayer(check)
        avatar.addSublayer(badge)
        return badge
    }

    /// Keeps the ring, glint and badge on the avatar's bounds and picture (after a layout or a new picture).
    static func fit(_ avatar: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let bounds = avatar.bounds
        if let ring = avatar.sublayers?.first(where: { $0.name == ringName }) as? CAShapeLayer {
            ring.frame = bounds
            let width = ringWidth(bounds)
            ring.lineWidth = width
            let circle = bounds.insetBy(dx: width / 2, dy: width / 2)
            ring.path = CGPath(ellipseIn: circle, transform: nil)
            if ring.lineDashPattern != nil {
                // Tool running's dots: a zero-length dash with round caps is a dot, evenly round the edge.
                let gap = Double.pi * circle.width / Double(dotCount)
                ring.lineDashPattern = [0, NSNumber(value: gap)]
            }
        }
        if let badge = avatar.sublayers?.first(where: { $0.name == badgeName }) as? CAShapeLayer {
            // 40 % of the avatar, its centre on the circle's lower trailing edge (45°). `down`: y grows
            // downward on screen (a flipped list), so "lower" and the check's points follow it.
            let down = avatar.contentsAreFlipped()
            let side = (bounds.width * 0.4).rounded()
            let edge = bounds.width / 2 * 0.707
            let centre = CGPoint(x: bounds.midX + edge, y: bounds.midY + (down ? edge : -edge))
            badge.frame = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
            badge.path = CGPath(ellipseIn: badge.bounds, transform: nil)
            if let check = badge.sublayers?.first as? CAShapeLayer {
                check.frame = badge.bounds
                check.lineWidth = max(1.2, side * 0.13)
                // The check's points as fractions of the badge, from its top left as seen.
                let point = { (x: CGFloat, top: CGFloat) in CGPoint(x: x * side, y: (down ? top : 1 - top) * side) }
                let path = CGMutablePath()
                path.move(to: point(0.28, 0.52))
                path.addLine(to: point(0.44, 0.68))
                path.addLine(to: point(0.72, 0.36))
                check.path = path
            }
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

    /// Whether `look` has a loop: only a running turn (thinking, a tool running) loops. Nothing runs at
    /// idle, waiting, done or failed (the idle budget, `plans/cmux-next/idle-wakeups.md`: 0.0% CPU with
    /// nothing changing).
    static func loops(_ look: SidebarAvatarMotion.Look) -> Bool {
        look.style != .still && look.mode.isRunning
    }

    /// Removes the look: every loop, the ring, glint and badge, the glow; the cue too unless `keepCue`.
    static func clear(_ avatar: CALayer, keepCue: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        avatar.removeAnimation(forKey: SidebarAvatarMotion.animationKey)
        if !keepCue { avatar.removeAnimation(forKey: SidebarAvatarMotion.cueKey) }
        avatar.sublayers?.filter { [ringName, glintName, badgeName].contains($0.name) }.forEach { $0.removeFromSuperlayer() }
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
        // Waiting on you: the attention colour, apart from the accent of a running turn.
        let attention = NSColor.systemOrange.cgColor
        switch (look.style, look.mode) {
        case (.still, _):
            return
        case (.glow, .idle):
            return
        case (.glow, .thinking):
            glow(avatar, color: accent, opacity: 0.35)
            if look.moving { sweep(avatar, period: workingGlintPeriod, phase: phase) }
        case (.glow, .tool):
            glow(avatar, color: accent, opacity: 0.35)
            dots(avatar, color: accent, moving: look.moving, phase: phase)
        case (.glow, .waiting):
            glow(avatar, color: attention, opacity: 0.55)
        case (.glow, .done):
            _ = badge(avatar)
        case (.glow, .failed):
            glow(avatar, color: red, opacity: 0.55)
        case (.ring, .idle), (.tilt, .idle):
            // At rest: nothing runs while nothing changes. Ring's glint plays once, as a state change's cue.
            return
        case (.ring, .thinking):
            arc(avatar, color: accent, moving: look.moving, phase: phase)
        case (.tilt, .thinking):
            if look.moving { tilt(avatar, period: workingTiltPeriod, degrees: 4, phase: phase) }
        case (.ring, .tool), (.tilt, .tool):
            dots(avatar, color: accent, moving: look.moving, phase: phase)
        case (.ring, .waiting), (.tilt, .waiting):
            still(avatar, color: attention, opacity: 0.85)
        case (.ring, .done), (.tilt, .done):
            _ = badge(avatar)
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

    /// Thinking's arc: a quarter of the ring turning round the edge. Under Reduce Motion it stands, a
    /// still quarter, so the state still reads.
    static func arc(_ avatar: CALayer, color: CGColor, moving: Bool, phase: Double) {
        let ring = ring(avatar)
        ring.lineDashPattern = nil
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

    /// Tool running's ring of dots, turning slowly round the edge (the work is the tool's, not the
    /// model's: dots apart from thinking's single arc). Under Reduce Motion the dots stand.
    static func dots(_ avatar: CALayer, color: CGColor, moving: Bool, phase: Double) {
        let ring = ring(avatar)
        ring.strokeColor = color
        ring.strokeStart = 0
        ring.strokeEnd = 1
        ring.opacity = 0.9
        ring.lineDashPattern = [0, 1]  // set to the edge's length in `fit`
        guard moving else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = dotsPeriod
        turn.repeatCount = .infinity
        turn.timeOffset = phase * dotsPeriod
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

    /// The avatar rocks a few degrees about its centre (Tilt's working loop).
    static func tilt(_ avatar: CALayer, period: CFTimeInterval, degrees: Double, phase: Double) {
        let angle = degrees * .pi / 180
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        turn.values = [0, angle, 0, -angle, 0]
        turn.keyTimes = [0, 0.25, 0.5, 0.75, 1].map { NSNumber(value: $0) }
        turn.calculationMode = .cubic
        turn.duration = period
        turn.repeatCount = .infinity
        turn.timeOffset = phase * period
        turn.isRemovedOnCompletion = false
        avatar.add(turn, forKey: SidebarAvatarMotion.animationKey)
    }

    // MARK: Cues

    /// One glint across the face, then nothing: Ring's cue on a state change (at most ``cueDuration``).
    static func glintOnce(_ avatar: CALayer) {
        let glint = glint(avatar)
        fit(avatar)
        guard let band = glint.sublayers?.first else { return }
        let width = max(avatar.bounds.width, 1)
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -width * 0.5
        move.toValue = width * 1.5
        move.duration = cueDuration
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        move.isRemovedOnCompletion = true
        band.add(move, forKey: SidebarAvatarMotion.cueKey)
    }

    /// The one-shot of a change from `from` to `to`, if it has one: a turn ending (thinking or a tool
    /// to idle, waiting or done) pops the avatar 4 %; a failure shakes it a few degrees about its centre;
    /// a question waiting with no turn seen fades its ring in (Glow has no ring: nothing); done with no
    /// turn seen pops its badge in. At most ``cueDuration``.
    enum Cue: Equatable {
        case pop
        case shake
        case ringIn
        case badgeIn
    }

    static func cue(from: SidebarAvatarMotion.Mode, to: SidebarAvatarMotion.Mode) -> Cue? {
        switch (from, to) {
        case (_, .failed): .shake
        case (_, .thinking), (_, .tool): nil
        case (.thinking, _), (.tool, _): .pop
        case (_, .waiting): .ringIn
        case (_, .done): .badgeIn
        default: nil
        }
    }

    static func cue(_ avatar: CALayer, style: CmuxSidebarAvatarMotionStyle, from: SidebarAvatarMotion.Mode, to: SidebarAvatarMotion.Mode) {
        guard style != .still else { return }
        // Ring: every state change glints once across the face (the pet's blink, never a loop at idle).
        if style == .ring, !to.isRunning { glintOnce(avatar) }
        guard let cue = cue(from: from, to: to) else { return }
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
        case .badgeIn:
            // Done's badge (just drawn) grows in from 60 %; the avatar itself stays as it is.
            guard let badge = avatar.sublayers?.first(where: { $0.name == badgeName }) else { return }
            let grow = CAKeyframeAnimation(keyPath: "transform.scale")
            grow.values = [0.6, 1.08, 1]
            grow.keyTimes = [0, 0.6, 1]
            grow.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            animation = grow
            target = badge
        }
        animation.duration = cueDuration
        animation.isRemovedOnCompletion = true
        target.add(animation, forKey: SidebarAvatarMotion.cueKey)
    }
}
