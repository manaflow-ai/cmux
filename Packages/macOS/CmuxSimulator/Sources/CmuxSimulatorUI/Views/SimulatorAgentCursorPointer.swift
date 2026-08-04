import CmuxSimulator
import SwiftUI

struct SimulatorAgentCursorPointer: View {
    let phase: SimulatorAgentCursorPhase
    let pulseScale: CGFloat
    let pulseOpacity: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 45 / 255, green: 140 / 255, blue: 1).opacity(
                    phase == .pressed ? 0.43 : 0
                ))
                .frame(width: 13, height: 13)
            Circle()
                .stroke(
                    Color(red: 45 / 255, green: 140 / 255, blue: 1).opacity(
                        phase == .pressed ? 0.82 : 0
                    ),
                    lineWidth: 3
                )
                .frame(width: 26, height: 26)
            Circle()
                .stroke(
                    Color(red: 45 / 255, green: 140 / 255, blue: 1),
                    lineWidth: 2.5
                )
                .frame(width: 26, height: 26)
                .scaleEffect(pulseScale)
                .opacity(pulseOpacity)
            skyKite
                .offset(x: 8.8, y: 8.8)
        }
        .frame(width: 52, height: 52)
    }

    private var skyKite: some View {
        ZStack {
            SimulatorAgentCursorShape()
                .stroke(.white, lineWidth: 2.4)
            SimulatorAgentCursorShape()
                .fill(LinearGradient(
                    colors: [
                        Color(red: 18 / 255, green: 199 / 255, blue: 245 / 255),
                        Color(red: 45 / 255, green: 140 / 255, blue: 1),
                        Color(red: 108 / 255, green: 92 / 255, blue: 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        }
        .frame(width: 26, height: 26)
    }
}
