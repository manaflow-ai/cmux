#if os(iOS)
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Easing helpers for the welcome intro. Every value is a pure function of the
/// time since the intro started, so the intro is one clock and never drifts.
enum IntroEase {
    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    /// Linear progress of `t` through the window `a...b`, clamped to 0...1.
    static func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
    static func inOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func out(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func outQuint(_ x: Double) -> Double { 1 - pow(1 - x, 5) }
    static func inCubic(_ x: Double) -> Double { x * x * x }
    static func outBack(_ x: Double, overshoot s: Double = 1.6) -> Double {
        let c3 = s + 1
        return 1 + c3 * pow(x - 1, 3) + s * pow(x - 1, 2)
    }
    /// A critically under-damped spring from 0 to 1, as SwiftUI's
    /// `.spring(duration:bounce:)` moves, `x` seconds in.
    static func spring(_ x: Double, duration: Double, bounce: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < duration else { return 1 }
        let zeta = 1 - bounce
        let omega = 2 * Double.pi / duration
        let damped = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * x) * (cos(damped * x) + zeta * omega / damped * sin(damped * x))
    }
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ x: Double) -> CGFloat { a + (b - a) * CGFloat(x) }
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ x: Double) -> CGPoint {
        CGPoint(x: lerp(a.x, b.x, x), y: lerp(a.y, b.y, x))
    }
}

/// The welcome illustration (onboarding design spec, section 2): a Mac and an
/// iPhone drawn as one line, a prompt on the Mac, then one thread that arcs
/// from the prompt to the phone. A dot rides it across and blooms into the
/// cmux chevron on the phone's screen; the thread retracts. Nothing moves
/// outside the two devices and the thread's arc.
/// `t` is seconds since the intro started (`.infinity` = settled);
/// `idle` is seconds into the one idle event, or nil. Connect your Mac rests
/// it at `rideStart` (devices drawn, no chevron) while it waits, and plays on
/// from there when a Mac appears.
struct WelcomeArt: View {
    var t: Double
    var idle: Double?
    /// How the idle event plays (the welcome's, or Connect your Mac's wait).
    var idleStyle: IdleStyle = .welcome
    /// Drawn width; the drawing scales to it (260 on the welcome).
    var width: CGFloat = Self.size.width

    /// The drawing's own box: the devices, the thread's arc above them and
    /// the chevron's glow, with nothing empty around them.
    static let size = CGSize(width: 260, height: 136)
    /// When the intro's last element settles.
    static let introDuration: Double = 4.1
    /// The intro time the thread starts growing: Connect your Mac rests here
    /// while it waits, and plays on from here when a Mac appears.
    static let rideStart: Double = 1.6
    /// The welcome's idle event length.
    static var idleDuration: Double { IdleStyle.welcome.duration }

    /// An idle event: the thread re-draws faintly, a dot travels it, the
    /// chevron's glow beats (when there is one), the thread fades.
    struct IdleStyle: Sendable {
        var duration: Double
        var draw: ClosedRange<Double>
        var ride: ClosedRange<Double>
        var beat: ClosedRange<Double>
        var fade: ClosedRange<Double>
        var dotOpacity: Double

        /// The welcome's one idle event (2.1 s), the dot at full strength.
        static let welcome = IdleStyle(duration: 2.1, draw: 0...0.5, ride: 0.5...1.5, beat: 1.4...1.8, fade: 1.8...2.1, dotOpacity: 1)
        /// Connect your Mac's wait (1.5 s every 2.4 s), everything at 35%.
        static let waiting = IdleStyle(duration: 1.5, draw: 0...0.5, ride: 0.5...1.3, beat: 1.2...1.5, fade: 1.2...1.5, dotOpacity: 0.35)
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let scale = width / Self.size.width
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: 0, y: Self.drawingOffset)
            draw(in: &context)
        }
        .frame(width: width, height: Self.size.height * scale)
        .accessibilityHidden(true)
    }

    // MARK: Geometry (the drawing's coordinates; shifted up into the box)

    /// The drawing spans y 36...170 (thread peak and glow to the base).
    private static let drawingOffset: CGFloat = -36
    private static let lineWidth: CGFloat = 3.3
    private static let screen = CGRect(x: 18, y: 50, width: 140, height: 94)
    private static let phone = CGRect(x: 192, y: 54, width: 54, height: 104)
    private static var phoneCenter: CGPoint { CGPoint(x: phone.midX, y: phone.midY + 2) }

    /// A rounded rectangle traced clockwise from the middle of its top edge, so
    /// a trimmed stroke draws it like a pen would.
    private static func roundRect(_ r: CGRect, radius: CGFloat, into path: inout Path) {
        path.move(to: CGPoint(x: r.midX, y: r.minY))
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.midX, y: r.minY), radius: radius)
        path.closeSubpath()
    }

    private static let mac: Path = {
        var p = Path()
        roundRect(screen, radius: 10, into: &p)
        // The base: a lip wider than the screen, with the hinge notch.
        p.move(to: CGPoint(x: 4, y: 150))
        p.addLine(to: CGPoint(x: 70, y: 150))
        p.addQuadCurve(to: CGPoint(x: 106, y: 150), control: CGPoint(x: 88, y: 156))
        p.addLine(to: CGPoint(x: 172, y: 150))
        p.addQuadCurve(to: CGPoint(x: 160, y: 160), control: CGPoint(x: 170, y: 160))
        p.addLine(to: CGPoint(x: 16, y: 160))
        p.addQuadCurve(to: CGPoint(x: 4, y: 150), control: CGPoint(x: 6, y: 160))
        return p
    }()

    private static let iPhone: Path = {
        var p = Path()
        roundRect(phone, radius: 14, into: &p)
        p.move(to: CGPoint(x: phone.midX - 8, y: phone.minY + 9))
        p.addLine(to: CGPoint(x: phone.midX + 8, y: phone.minY + 9))
        return p
    }()

    private static let prompt: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 36, y: 72))
        p.addLine(to: CGPoint(x: 47, y: 81))
        p.addLine(to: CGPoint(x: 36, y: 90))
        p.move(to: CGPoint(x: 54, y: 91))
        p.addLine(to: CGPoint(x: 68, y: 91))
        return p
    }()

    /// The thread: one quadratic curve from just past the prompt's cursor,
    /// up and over the gap, down to the phone's screen center. Its control
    /// point is 40 pt above the higher end, so the arc stays inside the
    /// screens' height and never runs along an outline.
    private static let threadStart = CGPoint(x: 74, y: 86)
    private static var threadEnd: CGPoint { phoneCenter }
    private static var threadControl: CGPoint {
        CGPoint(x: (threadStart.x + threadEnd.x) / 2, y: min(threadStart.y, threadEnd.y) - 40)
    }
    private static let thread: Path = {
        var p = Path()
        p.move(to: threadStart)
        p.addQuadCurve(to: threadEnd, control: threadControl)
        return p
    }()

    /// The curve parameter at each 1/64 of the thread's length, so the dot
    /// rides at the same pace a trimmed stroke grows.
    private static let threadLookup: [Double] = {
        let samples = 256
        var lengths: [CGFloat] = [0]
        var last = threadStart
        for i in 1...samples {
            let p = curvePoint(Double(i) / Double(samples))
            lengths.append(lengths[i - 1] + hypot(p.x - last.x, p.y - last.y))
            last = p
        }
        let total = lengths[samples]
        var table: [Double] = []
        var j = 0
        for k in 0...64 {
            let target = total * CGFloat(k) / 64
            while j < samples, lengths[j + 1] < target { j += 1 }
            let span = max(lengths[j + 1] - lengths[j], 0.0001)
            table.append((Double(j) + Double((target - lengths[j]) / span)) / Double(samples))
        }
        return table
    }()

    private static func curvePoint(_ u: Double) -> CGPoint {
        let a = threadStart, c = threadControl, b = threadEnd
        let v = CGFloat(1 - u), w = CGFloat(u)
        return CGPoint(x: v * v * a.x + 2 * v * w * c.x + w * w * b.x, y: v * v * a.y + 2 * v * w * c.y + w * w * b.y)
    }

    /// The point `fraction` of the way along the thread, by length.
    private static func threadPoint(_ fraction: Double) -> CGPoint {
        let f = IntroEase.clamp(fraction) * 64
        let i = min(Int(f), 63)
        let u = threadLookup[i] + (threadLookup[i + 1] - threadLookup[i]) * (f - Double(i))
        return curvePoint(u)
    }

    /// The app icon's gradient, sampled across the drawing.
    private static func accent(atX x: CGFloat) -> Color {
        let stops: [(CGFloat, (Double, Double, Double))] = [
            (60, (0x06, 0xCD, 0xFE)), (150, (0x2A, 0xA0, 0xF9)), (230, (0x51, 0x70, 0xF3)),
        ]
        func rgb(_ c: (Double, Double, Double)) -> Color { Color(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255) }
        if x <= stops[0].0 { return rgb(stops[0].1) }
        for i in 1..<stops.count where x <= stops[i].0 {
            let (x0, a) = stops[i - 1], (x1, b) = stops[i]
            let f = Double((x - x0) / (x1 - x0))
            return rgb((a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f))
        }
        return rgb(stops[stops.count - 1].1)
    }

    private static let iconGradient = Gradient(colors: [Color(hex: "#06CDFE"), Color(hex: "#2AA0F9"), Color(hex: "#5170F3")])
    private static var threadShading: GraphicsContext.Shading {
        .linearGradient(iconGradient, startPoint: CGPoint(x: threadStart.x, y: 0), endPoint: CGPoint(x: threadEnd.x, y: 0))
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext) {
        typealias E = IntroEase
        let ink = theme.colors.label.color
        let stroke = StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
        let threadStroke = StrokeStyle(lineWidth: 2.5, lineCap: .round)

        // 1. The Mac (screen, then base) and the phone, each one pen stroke.
        let macDraw = E.inOut(E.seg(t, 0.1, 1.3))
        if macDraw > 0 { context.stroke(Self.mac.trimmedPath(from: 0, to: macDraw), with: .color(ink), style: stroke) }
        let phoneDraw = E.inOut(E.seg(t, 0.7, 1.5))
        if phoneDraw > 0 { context.stroke(Self.iPhone.trimmedPath(from: 0, to: phoneDraw), with: .color(ink), style: stroke) }

        // 2. The prompt types in on the Mac, in the icon's cyan.
        let promptDraw = E.out(E.seg(t, 1.3, 1.6))
        if promptDraw > 0 {
            context.stroke(
                Self.prompt.trimmedPath(from: 0, to: promptDraw),
                with: .linearGradient(Self.iconGradient, startPoint: CGPoint(x: 30, y: 0), endPoint: CGPoint(x: 120, y: 0)),
                style: stroke
            )
        }

        // 3. The thread grows from the prompt to the phone, then retracts
        //    toward the phone once the dot has arrived.
        let grow = E.inOut(E.seg(t, 1.6, 2.2))
        let retract = E.inCubic(E.seg(t, 3.6, 4.1))
        if grow > 0, retract < 1 {
            context.stroke(Self.thread.trimmedPath(from: retract, to: grow), with: Self.threadShading, style: threadStroke)
        }

        // 4. A dot rides the thread from the Mac to the phone.
        if t >= 2.2, t < 3.35 {
            let ride = E.inOut(E.seg(t, 2.2, 3.2))
            let shrink = 1 - E.seg(t, 3.2, 3.35)
            drawDot(in: &context, at: Self.threadPoint(ride), radius: 3.5 * shrink, opacity: E.seg(t, 2.2, 2.3))
        }

        // 5. It grows into the chevron on the phone's screen, with a soft glow;
        //    the idle event makes the glow beat once.
        let bloom = E.spring(t - 3.2, duration: 0.5, bounce: 0.25)
        if bloom > 0 {
            var scale = bloom
            var glow = E.seg(t, 3.25, 3.7)
            if let idle {
                let beat = sin(.pi * E.seg(idle, idleStyle.beat.lowerBound, idleStyle.beat.upperBound))
                scale *= 1 + 0.08 * beat
                glow += 0.6 * beat
            }
            drawChevron(in: &context, side: 26 * CGFloat(scale), glow: glow, opacity: E.seg(t, 3.2, 3.32))
        }

        if let idle { drawIdle(in: &context, u: idle, stroke: threadStroke) }
    }

    private func drawDot(in context: inout GraphicsContext, at p: CGPoint, radius r: CGFloat, opacity: Double) {
        guard r > 0, opacity > 0 else { return }
        context.drawLayer { layer in
            layer.opacity = opacity
            layer.addFilter(.shadow(color: Color(hex: "#2AA0F9").opacity(colorScheme == .dark ? 0.6 : 0.3), radius: 4))
            layer.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(Self.accent(atX: p.x)))
        }
    }

    private func drawChevron(in context: inout GraphicsContext, side: CGFloat, glow: Double, opacity: Double) {
        let c = Self.phoneCenter
        let rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        let mark = CmuxMark().path(in: rect)
        let dark = colorScheme == .dark
        context.drawLayer { layer in
            layer.opacity = opacity
            layer.addFilter(.shadow(color: Color(hex: "#2AA0F9").opacity((dark ? 0.7 : 0.35) * min(glow, 1.4)), radius: 6 + 6 * glow))
            layer.fill(mark, with: .linearGradient(Self.iconGradient, startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
        }
    }

    /// The idle event (`idleStyle`): the thread re-draws at 35%, a dot
    /// travels it, the chevron's glow beats (in `draw`), the thread fades.
    private func drawIdle(in context: inout GraphicsContext, u: Double, stroke: StrokeStyle) {
        typealias E = IntroEase
        let style = idleStyle
        let grow = E.inOut(E.seg(u, style.draw.lowerBound, style.draw.upperBound))
        let fade = 1 - E.seg(u, style.fade.lowerBound, style.fade.upperBound)
        if grow > 0, fade > 0 {
            context.drawLayer { layer in
                layer.opacity = 0.35 * fade
                layer.stroke(Self.thread.trimmedPath(from: 0, to: grow), with: Self.threadShading, style: stroke)
            }
        }
        let (start, end) = (style.ride.lowerBound, style.ride.upperBound)
        if u >= start, u < end + 0.05 {
            let ride = E.inOut(E.seg(u, start, end))
            drawDot(in: &context, at: Self.threadPoint(ride), radius: 3.5 * (1 - E.seg(u, end - 0.05, end + 0.05)),
                    opacity: style.dotOpacity * E.seg(u, start, start + 0.1))
        }
    }
}
#endif
