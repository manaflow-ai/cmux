import AppKit
import Testing
@testable import MessagesLabSidebar

/// The gallery of a Chief avatar's state looks: one row per style, one strip per state (idle, thinking,
/// tool, waiting, done, failed) and one for the cues (a turn ending, a failure), each sampled into eight frames of a
/// synthetic orb (turns and scales drawn 3x so they read). Each frame is drawn from the real look: ``SidebarAvatarLooks/show(_:on:seed:)`` builds
/// its layers and animations, and the sheet applies their keyframes at that frame's time. One sheet is
/// written to the package's `.build/chief-avatar-motion-gallery.png` (ignored by git), which a fleet step
/// returns with `cmux-ci run --artifact Packages/Shared/CmuxMessagesLab/.build/chief-avatar-motion-gallery.png`.
@MainActor
@Suite(.serialized)
struct ChiefAvatarMotionGalleryTests {
    static let frames = 8
    static let cell: CGFloat = 56
    static let size: CGFloat = 36

    /// A property animation's value at `time` seconds (linear between keyframes, which reads well enough
    /// on a sheet; the loop's own timing curve is in the code).
    static func value(_ animation: CAAnimation?, at time: CFTimeInterval) -> Double? {
        guard let animation, animation.duration > 0 else { return nil }
        // From the loop's own start (no per-conversation phase), so each strip shows where it moves.
        let t = time.truncatingRemainder(dividingBy: animation.duration) / animation.duration
        if let basic = animation as? CABasicAnimation {
            let from = (basic.fromValue as? NSNumber)?.doubleValue ?? 0
            guard let to = (basic.toValue as? NSNumber)?.doubleValue else { return from }
            return from + (to - from) * t
        }
        guard let frames = animation as? CAKeyframeAnimation, let values = frames.values as? [NSNumber], !values.isEmpty else { return nil }
        let times = (frames.keyTimes?.map(\.doubleValue)) ?? values.indices.map { Double($0) / Double(max(values.count - 1, 1)) }
        for i in 1..<values.count where t <= times[i] {
            let span = max(times[i] - times[i - 1], 1e-9)
            let f = (t - times[i - 1]) / span
            return values[i - 1].doubleValue + (values[i].doubleValue - values[i - 1].doubleValue) * f
        }
        return values.last?.doubleValue
    }

    /// Draws `avatar`'s look at `time`: the glow, the face (turned and scaled by the avatar's own loop
    /// or cue), the glint across it and the ring on its edge.
    func draw(_ avatar: CALayer, at time: CFTimeInterval, cue: CAAnimation?, in rect: NSRect) {
        let key = SidebarAvatarMotion.animationKey
        var turn = 0.0, scale = 1.0
        for animation in [avatar.animation(forKey: key), cue].compactMap({ $0 as? CAPropertyAnimation }) {
            let v = Self.value(animation, at: time) ?? 0
            // 3x so a few degrees and a 4% pop read on the sheet.
            if animation.keyPath == "transform.rotation.z" { turn += v * 3 }
            if animation.keyPath == "transform.scale" { scale *= 1 + (v - 1) * 3 }
        }
        let d = Self.size
        let face = NSRect(x: -d / 2, y: -d / 2, width: d, height: d)
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byRadians: turn)
        transform.scale(by: scale)
        NSGraphicsContext.saveGraphicsState()
        transform.concat()
        if avatar.shadowOpacity > 0, let color = avatar.shadowColor.flatMap(NSColor.init(cgColor:)) {
            let shadow = NSShadow()
            shadow.shadowColor = color.withAlphaComponent(CGFloat(avatar.shadowOpacity))
            shadow.shadowBlurRadius = avatar.shadowRadius * 1.5
            shadow.set()
        }
        NSColor(calibratedRed: 0.42, green: 0.48, blue: 0.95, alpha: 1).setFill()
        NSBezierPath(ovalIn: face).fill()
        NSShadow().set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: -9, y: 1, width: 6, height: 7)).fill()
        NSBezierPath(ovalIn: NSRect(x: 3, y: 1, width: 6, height: 7)).fill()
        // The glint: its band's x from the band's own loop or its one-shot cue, clipped to the face.
        if let glint = avatar.sublayers?.first(where: { $0.name == SidebarAvatarLooks.glintName }),
           let band = glint.sublayers?.first,
           let x = Self.value(band.animation(forKey: key), at: time) ?? Self.value(band.animation(forKey: SidebarAvatarMotion.cueKey), at: time) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: face).addClip()
            let band = NSBezierPath(rect: NSRect(x: -d / 2 + x - d * 0.12, y: -d, width: d * 0.24, height: d * 2))
            let skew = NSAffineTransform()
            skew.rotate(byDegrees: -20)
            band.transform(using: skew as AffineTransform)
            NSColor(white: 1, alpha: 0.5).setFill()
            band.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        // The ring stays on the avatar's place (it turns, the face does not move).
        if let ring = avatar.sublayers?.first(where: { $0.name == SidebarAvatarLooks.ringName }) as? CAShapeLayer,
           let color = ring.strokeColor.flatMap(NSColor.init(cgColor:)) {
            let spin = Self.value(ring.animation(forKey: key), at: time) ?? 0
            let width = SidebarAvatarLooks.ringWidth(CGRect(x: 0, y: 0, width: d, height: d)) * 1.5
            let start = 90 + spin * 180 / .pi
            let sweep = Double(ring.strokeEnd - ring.strokeStart) * 360
            let path = NSBezierPath()
            path.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: d / 2 + width,
                           startAngle: start, endAngle: start - sweep, clockwise: true)
            path.lineWidth = width
            path.lineCapStyle = .round
            if ring.lineDashPattern != nil {
                // Tool running's dots, spaced as the look spaces them on the sheet's larger circle.
                var dash: [CGFloat] = [0, .pi * (d + 2 * width) / CGFloat(SidebarAvatarLooks.dotCount)]
                path.setLineDash(&dash, count: 2, phase: 0)
            }
            color.withAlphaComponent(CGFloat(ring.opacity)).setStroke()
            path.stroke()
        }
        // Done's badge on the lower trailing edge, as the look places it (the sheet's y grows upward).
        if let badge = avatar.sublayers?.first(where: { $0.name == SidebarAvatarLooks.badgeName }) as? CAShapeLayer {
            let grow = Self.value(badge.animation(forKey: SidebarAvatarMotion.cueKey), at: time) ?? 1
            let side = (d * 0.4).rounded() * grow
            let edge = d / 2 * 0.707
            let disc = NSRect(x: rect.midX + edge - side / 2, y: rect.midY - edge - side / 2, width: side, height: side)
            (badge.fillColor.flatMap(NSColor.init(cgColor:)) ?? .systemGreen).setFill()
            NSBezierPath(ovalIn: disc).fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: disc.minX + side * 0.28, y: disc.maxY - side * 0.52))
            check.line(to: NSPoint(x: disc.minX + side * 0.44, y: disc.maxY - side * 0.68))
            check.line(to: NSPoint(x: disc.minX + side * 0.72, y: disc.maxY - side * 0.36))
            check.lineWidth = max(1.2, side * 0.13)
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        }
    }

    @Test func drawsEveryStyleInEveryStateAndItsCues() throws {
        let styles = CmuxSidebarAvatarMotionStyle.allCases
        let modes = SidebarAvatarMotion.Mode.allCases
        // The strips: each state, then the cues (a turn ending, a failure).
        let strips = modes.count + 2
        let gap: CGFloat = 16
        let strip = CGFloat(Self.frames) * Self.cell
        let sheet = NSImage(size: NSSize(width: CGFloat(strips) * (strip + gap) + gap,
                                         height: CGFloat(styles.count) * (Self.cell + gap) + gap))
        sheet.lockFocus()
        NSColor(white: 0.96, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (row, style) in styles.enumerated() {
            for column in 0..<strips {
                let avatar = CALayer()
                avatar.bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
                var cue: CAAnimation?
                var period: CFTimeInterval = 1
                if column < modes.count {
                    let mode = modes[column]
                    if style != .still {
                        SidebarAvatarLooks.show(.init(style: style, mode: mode, moving: true), on: avatar, seed: "gallery")
                    }
                    let loops = ([avatar] + (avatar.sublayers ?? []).flatMap { [$0] + ($0.sublayers ?? []) })
                        .compactMap { $0.animation(forKey: SidebarAvatarMotion.animationKey) }
                    // Only a running turn loops; a strip with none (idle, waiting, done, failed) stands still.
                    period = loops.map { min($0.duration, 1.2) }.max() ?? 1
                } else {
                    let (from, to): (SidebarAvatarMotion.Mode, SidebarAvatarMotion.Mode) = column == modes.count ? (.tool, .done) : (.idle, .failed)
                    if style != .still {
                        SidebarAvatarLooks.show(.init(style: style, mode: to, moving: true), on: avatar, seed: "gallery")
                        SidebarAvatarLooks.cue(avatar, style: style, from: from, to: to)
                    }
                    cue = avatar.animation(forKey: SidebarAvatarMotion.cueKey)
                    period = cue?.duration ?? 1
                }
                for frame in 0..<Self.frames {
                    // Top row first: AppKit's y grows upward.
                    let origin = NSPoint(x: gap + CGFloat(column) * (strip + gap) + CGFloat(frame) * Self.cell,
                                         y: gap + CGFloat(styles.count - 1 - row) * (Self.cell + gap))
                    let time = period * Double(frame) / Double(Self.frames)
                    draw(avatar, at: time, cue: cue, in: NSRect(origin: origin, size: NSSize(width: Self.cell, height: Self.cell)))
                }
            }
        }
        sheet.unlockFocus()
        let tiff = try #require(sheet.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = package.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try png.write(to: build.appendingPathComponent("chief-avatar-motion-gallery.png"))
    }
}
