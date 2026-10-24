import CmuxNextDesign
import SwiftUI

/// Sleepy Mode's scene: a night sky with twinkling stars, a moon, drifting Zs,
/// the clock and how many of this Mac's agents run a turn. A click anywhere
/// but the Lock Mac button wakes it. The sky is Core Animation layers
/// (``NightSkyView``), so a scene left up for hours costs the main thread only
/// the clock's update once a second.
struct SleepySceneView: View {
    let workingAgents: @MainActor () -> Int
    let wake: @MainActor () -> Void
    let lockMac: @MainActor () -> Void

    var body: some View {
        ZStack {
            // The sky's loops run in the render server (NightSkyView): no frame runs app code.
            NightSky(loops: Motion.panes.animatesLoops)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            Color.clear
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
}
