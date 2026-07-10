import SwiftUI

/// The native SwiftUI pane that hosts one isolated iPhone or iPad Simulator.
public struct SimulatorPaneView: View {
    private let coordinator: SimulatorPaneCoordinator
    private let backgroundColor: Color
    private let onRequestPanelFocus: @MainActor () -> Void

    /// Creates a native Simulator pane.
    /// - Parameters:
    ///   - coordinator: The panel-owned Simulator coordinator.
    ///   - backgroundColor: The host application's resolved pane background.
    ///   - onRequestPanelFocus: Focuses the owning cmux panel before HID input.
    public init(
        coordinator: SimulatorPaneCoordinator,
        backgroundColor: Color,
        onRequestPanelFocus: @escaping @MainActor () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.backgroundColor = backgroundColor
        self.onRequestPanelFocus = onRequestPanelFocus
    }

    /// The composed Simulator toolbar, live device stage, and tools inspector.
    public var body: some View {
        VStack(spacing: 0) {
            SimulatorPaneToolbar(coordinator: coordinator)
            Divider()
            HStack(spacing: 0) {
                SimulatorDeviceStage(
                    coordinator: coordinator,
                    backgroundColor: backgroundColor,
                    onRequestPanelFocus: onRequestPanelFocus
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if coordinator.showsTools {
                    Divider()
                    SimulatorToolsPanel(
                        coordinator: coordinator,
                        backgroundColor: backgroundColor
                    )
                        .frame(width: 270)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .task {
            await coordinator.start()
        }
    }
}
