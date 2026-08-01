import CmuxSimulator
import SwiftUI

private struct SimulatorAgentCursorPhaseTaskID: Equatable {
    let generation: UInt64
    let phase: SimulatorAgentCursorPhase
    let delayMilliseconds: Int
}

struct SimulatorAgentCursorOverlay: View {
    let presentation: SimulatorAgentCursorPresentation
    let chrome: SimulatorDeviceChromeProfile?
    let orientation: SimulatorOrientation

    @State private var position: SimulatorPoint
    @State private var renderedPhase: SimulatorAgentCursorPhase
    @State private var pulseScale: CGFloat = 0.4
    @State private var pulseOpacity = 0.0

    init(
        presentation: SimulatorAgentCursorPresentation,
        chrome: SimulatorDeviceChromeProfile?,
        orientation: SimulatorOrientation
    ) {
        self.presentation = presentation
        self.chrome = chrome
        self.orientation = orientation
        _position = State(initialValue: presentation.origin)
        _renderedPhase = State(initialValue: presentation.phase)
    }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let screen = chrome?.swiftUIScreenRect(
                in: bounds,
                orientation: orientation
            ) ?? bounds
            SimulatorAgentCursorPointer(
                phase: renderedPhase,
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
            pulseOpacity = 0
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(
                duration: Double(presentation.durationMilliseconds) / 1_000
            )) {
                position = presentation.destination
            }
        }
        .task(id: SimulatorAgentCursorPhaseTaskID(
            generation: presentation.generation,
            phase: presentation.phase,
            delayMilliseconds: presentation.clickPhaseDelayMilliseconds
        )) {
            let phase = presentation.phase
            pulseScale = 0.4
            pulseOpacity = 0
            if phase == .clicked,
               presentation.clickPhaseDelayMilliseconds > 0 {
                do {
                    try await ContinuousClock().sleep(for: .milliseconds(
                        presentation.clickPhaseDelayMilliseconds
                    ))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            renderedPhase = phase
            if phase == .clicked {
                pulseOpacity = 0.9
                withAnimation(.easeOut(duration: 0.45)) {
                    pulseScale = 1.7
                    pulseOpacity = 0
                }
            }
        }
    }
}
