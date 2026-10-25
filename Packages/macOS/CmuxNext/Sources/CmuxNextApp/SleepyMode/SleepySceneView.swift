import AppKit
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
                    .glassButtonStyle()
                    .controlSize(.large)
                    .padding(.top, 12)
                Text(SleepyModeStrings.hint)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
                    .allowsHitTesting(false)
            }
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.12))
        // The scene is a night sky in every appearance: its controls draw for a dark surface (in Light
        // Mode the Lock Mac button had dark text on a clear bezel, near-invisible on the sky).
        .environment(\.colorScheme, .dark)
    }
}

extension SleepySceneView {
    /// The scene as an AppKit view, for a window's `contentView`: the overlay windows and the
    /// scene's tests take this, so only this file bridges the scene into AppKit.
    static func hostView(workingAgents: @escaping @MainActor () -> Int,
                         wake: @escaping @MainActor () -> Void,
                         lockMac: @escaping @MainActor () -> Void) -> NSView {
        NSHostingView(rootView: SleepySceneView(workingAgents: workingAgents, wake: wake, lockMac: lockMac))
    }
}

/// Hosts ``NightSkyView`` (Core Animation, in CmuxNextDesign) in the SwiftUI scene. It lives here,
/// beside its only consumer, so CmuxNextDesign's sky stays AppKit; it goes when the scene is AppKit.
private struct NightSky: NSViewRepresentable {
    /// Whether the stars twinkle and the Zs rise (``NightSkyView/loops``).
    var loops: Bool

    func makeNSView(context: Context) -> NightSkyView {
        let view = NightSkyView(frame: .zero)
        view.loops = loops
        return view
    }

    func updateNSView(_ view: NightSkyView, context: Context) {
        view.loops = loops
    }
}
