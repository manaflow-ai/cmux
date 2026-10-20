import CmuxNextDesign
import SwiftUI

/// Sleepy Mode's scene: a night sky with twinkling stars, a moon, drifting Zs,
/// the clock and how many of this Mac's agents run a turn. A click anywhere
/// but the Lock Mac button wakes it. Drawn at 10 frames a second, so a scene
/// left up for hours stays cheap.
struct SleepySceneView: View {
    let workingAgents: @MainActor () -> Int
    let wake: @MainActor () -> Void
    let lockMac: @MainActor () -> Void

    var body: some View {
        ZStack {
            Group {
                if Motion.panes.animatesLoops {
                    // motion: allow the scene's 10 fps loop runs only while Motion.panes.animatesLoops
                    TimelineView(.animation(minimumInterval: 0.1)) { context in
                        Self.sky(time: context.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    // Motion off (the master switch, Panes and Windows, speed off or Reduce Motion): a still sky.
                    Self.sky(time: 0)
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { wake() }
            VStack(spacing: 18) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 96, weight: .regular))
                    .foregroundStyle(Color(red: 1.0, green: 0.92, blue: 0.62))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 8) {
                        Text(context.date, format: .dateTime.hour().minute())
                            .font(.system(size: 64, weight: .thin, design: .rounded))
                            .monospacedDigit()
                        let working = workingAgents()
                        Text(working == 0 ? SleepyModeStrings.noAgentsWorking : SleepyModeStrings.agentsWorking(working))
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .foregroundStyle(.white)
                .allowsHitTesting(false)
                Button(SleepyModeStrings.lockMac, systemImage: "lock.fill") { lockMac() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.white)
                    .padding(.top, 12)
                Text(SleepyModeStrings.hint)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
                    .allowsHitTesting(false)
            }
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.12))
    }

    /// Stars at fixed spots (a seeded walk, the same on every frame) that
    /// twinkle, and three Zs rising from the moon's corner.
    /// The sky at `time` (seconds since the reference date).
    private static func sky(time: TimeInterval) -> some View {
        Canvas { canvas, size in
            drawSky(canvas, size: size, time: time)
        }
    }

    private static func drawSky(_ canvas: GraphicsContext, size: CGSize, time: TimeInterval) {
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for _ in 0..<90 {
            let x = next() * size.width, y = next() * size.height
            let phase = next() * .pi * 2, radius = 0.6 + next() * 1.4
            let alpha = 0.35 + 0.65 * (0.5 + 0.5 * sin(time * 1.3 + phase))
            canvas.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(.white.opacity(alpha)))
        }
        let origin = CGPoint(x: size.width / 2 + 60, y: size.height / 2 - 150)
        for index in 0..<3 {
            let progress = (time / 3 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            let point = CGPoint(x: origin.x + progress * 50 + sin(progress * .pi * 2) * 8, y: origin.y - progress * 90)
            let text = Text(verbatim: "z").font(.system(size: 18 + progress * 18, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(1 - progress))
            canvas.draw(text, at: point)
        }
    }
}
