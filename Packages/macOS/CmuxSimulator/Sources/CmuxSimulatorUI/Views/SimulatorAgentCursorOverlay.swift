import CmuxSimulator
import SwiftUI

struct SimulatorAgentCursorOverlay: View {
    let presentation: SimulatorAgentCursorPresentation
    let chrome: SimulatorDeviceChromeProfile?
    let orientation: SimulatorOrientation
    let onDismiss: (UInt64) -> Void

    @State private var position: SimulatorPoint
    @State private var pulseScale: CGFloat = 0.4
    @State private var pulseOpacity = 0.0

    init(
        presentation: SimulatorAgentCursorPresentation,
        chrome: SimulatorDeviceChromeProfile?,
        orientation: SimulatorOrientation,
        onDismiss: @escaping (UInt64) -> Void
    ) {
        self.presentation = presentation
        self.chrome = chrome
        self.orientation = orientation
        self.onDismiss = onDismiss
        _position = State(initialValue: presentation.origin)
    }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let screen = simulatorPresentedScreenRect(
                in: bounds,
                chrome: chrome,
                orientation: orientation
            )
            SimulatorAgentCursorPointer(
                phase: presentation.phase,
                pulseScale: pulseScale,
                pulseOpacity: pulseOpacity
            )
            .position(
                x: screen.minX + position.x * screen.width,
                y: screen.minY + position.y * screen.height
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: presentation.generation) {
            position = presentation.origin
            pulseScale = 0.4
            pulseOpacity = presentation.phase == .clicked ? 0.9 : 0
            await Task.yield()
            withAnimation(.linear(
                duration: Double(presentation.durationMilliseconds) / 1_000
            )) {
                position = presentation.destination
            }
            if presentation.phase == .clicked {
                withAnimation(.easeOut(duration: 0.45)) {
                    pulseScale = 1.7
                    pulseOpacity = 0
                }
            }
            guard presentation.phase != .pressed else { return }
            let delay: Duration = presentation.phase == .clicked
                ? .milliseconds(1_250)
                : .milliseconds(300)
            do {
                try await ContinuousClock().sleep(for: delay)
            } catch {
                return
            }
            onDismiss(presentation.generation)
        }
    }
}

private struct SimulatorAgentCursorPointer: View {
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
