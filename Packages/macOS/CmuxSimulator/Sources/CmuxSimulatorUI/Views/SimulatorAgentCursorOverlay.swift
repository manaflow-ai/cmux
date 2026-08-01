import CmuxSimulator
import SwiftUI

struct SimulatorAgentCursorOverlay: View {
    let presentation: SimulatorAgentCursorPresentation
    let chrome: SimulatorDeviceChromeProfile?
    let orientation: SimulatorOrientation

    @State private var position: SimulatorPoint
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
    }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let screen = chrome?.swiftUIScreenRect(
                in: bounds,
                orientation: orientation
            ) ?? bounds
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
            pulseOpacity = 0
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(
                duration: Double(presentation.durationMilliseconds) / 1_000
            )) {
                position = presentation.destination
            }
        }
        .onChange(of: presentation.phase, initial: true) { _, phase in
            pulseScale = 0.4
            pulseOpacity = phase == .clicked ? 0.9 : 0
            if phase == .clicked {
                withAnimation(.easeOut(duration: 0.45)) {
                    pulseScale = 1.7
                    pulseOpacity = 0
                }
            }
        }
    }
}
