import SwiftUI

/// Cute sleeping face for Sleepy Mode. The face breathes (gentle scale + bob),
/// keeps its eyes softly closed, peeks open every so often, and drifts little
/// "z" letters upward. Everything is a pure function of the timeline date, so
/// there is no mutable animation state to manage.
struct SleepyFaceView: View {
    private let faceColor = Color(red: 0.86, green: 0.92, blue: 1.0)
    private let blushColor = Color(red: 1.0, green: 0.62, blue: 0.72)

    var body: some View {
        ZStack {
            backgroundGradient
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    draw(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            hint
        }
        .ignoresSafeArea()
    }

    private var backgroundGradient: some View {
        RadialGradient(
            colors: [
                Color(red: 0.07, green: 0.09, blue: 0.16),
                Color(red: 0.02, green: 0.02, blue: 0.05),
            ],
            center: .center,
            startRadius: 0,
            endRadius: 900
        )
    }

    private var hint: some View {
        VStack {
            Spacer()
            Text(String(localized: "sleepyMode.dismissHint", defaultValue: "Touch ID or password to unlock"))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(faceColor.opacity(0.35))
                .padding(.bottom, 44)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time t: Double) {
        let s = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.46)

        let breath = sin(t * 2 * .pi / 4.6)
        let scale = 1.0 + 0.028 * breath
        let bob = -6.0 * breath
        let openness = eyeOpenness(t)

        // Floating "z z z" drawn in absolute coordinates so they drift
        // independently of the breathing face.
        drawSleepZs(in: &context, origin: CGPoint(x: center.x + 0.17 * s, y: center.y - 0.16 * s), s: s, time: t)

        context.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y + bob)
            layer.scaleBy(x: scale, y: scale)

            let eyeY = -0.02 * s
            let eyeDX = 0.14 * s
            drawEye(in: &layer, center: CGPoint(x: -eyeDX, y: eyeY), s: s, openness: openness)
            drawEye(in: &layer, center: CGPoint(x: eyeDX, y: eyeY), s: s, openness: openness)

            // Soft blush under each eye.
            let blushY = 0.05 * s
            let blushDX = 0.19 * s
            let blushR = 0.045 * s
            for dx in [-blushDX, blushDX] {
                let rect = CGRect(x: dx - blushR, y: blushY - blushR * 0.7, width: blushR * 2, height: blushR * 1.4)
                layer.fill(Ellipse().path(in: rect), with: .color(blushColor.opacity(0.22)))
            }

            // Breathing mouth: a small soft "o" that opens slightly on the inhale.
            let mouthOpen = 0.012 * s + 0.010 * s * max(0, breath)
            let mouthW = 0.05 * s
            let mouthRect = CGRect(x: -mouthW / 2, y: 0.10 * s - mouthOpen / 2, width: mouthW, height: mouthOpen)
            layer.fill(Ellipse().path(in: mouthRect), with: .color(faceColor.opacity(0.85)))
        }
    }

    /// Mostly closed (asleep); briefly peeks to about half-open every ~13s.
    private func eyeOpenness(_ t: Double) -> Double {
        let period = 13.0
        let phase = t.truncatingRemainder(dividingBy: period)
        let peekDuration = 1.3
        guard phase < peekDuration else { return 0 }
        let p = phase / peekDuration
        return sin(p * .pi) * 0.55
    }

    private func drawEye(in context: inout GraphicsContext, center: CGPoint, s: CGFloat, openness: Double) {
        let halfWidth = 0.06 * s

        // Closed eye: a gentle happy arc (visible when openness is low).
        if openness < 0.999 {
            var arc = Path()
            let dip = 0.035 * s
            arc.move(to: CGPoint(x: center.x - halfWidth, y: center.y))
            arc.addQuadCurve(
                to: CGPoint(x: center.x + halfWidth, y: center.y),
                control: CGPoint(x: center.x, y: center.y + dip)
            )
            context.stroke(
                arc,
                with: .color(faceColor.opacity(1.0 - openness)),
                style: StrokeStyle(lineWidth: 0.014 * s, lineCap: .round)
            )
        }

        // Open eye: a soft filled oval that fades in as the eye peeks.
        if openness > 0.001 {
            let h = 0.07 * s * openness
            let w = 0.075 * s
            let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
            context.fill(Ellipse().path(in: rect), with: .color(faceColor.opacity(openness)))
        }
    }

    private func drawSleepZs(in context: inout GraphicsContext, origin: CGPoint, s: CGFloat, time t: Double) {
        let count = 3
        let period = 3.6
        for i in 0..<count {
            let progress = ((t / period) + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
            let x = origin.x + 0.11 * s * progress
            let y = origin.y - 0.24 * s * progress
            let opacity = sin(progress * .pi) * 0.85
            let fontSize = (0.035 + 0.05 * progress) * s
            let text = Text(verbatim: "z")
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundColor(faceColor.opacity(opacity))
            context.draw(context.resolve(text), at: CGPoint(x: x, y: y))
        }
    }
}
