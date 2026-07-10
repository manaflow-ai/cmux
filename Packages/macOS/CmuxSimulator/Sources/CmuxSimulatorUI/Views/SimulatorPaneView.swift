import SwiftUI

/// The native SwiftUI pane that hosts one isolated iPhone or iPad Simulator.
public struct SimulatorPaneView: View {
    private let coordinator: SimulatorPaneCoordinator
    private let onRequestPanelFocus: @MainActor () -> Void

    /// Creates a native Simulator pane.
    /// - Parameters:
    ///   - coordinator: The panel-owned Simulator coordinator.
    ///   - onRequestPanelFocus: Focuses the owning cmux panel before HID input.
    public init(
        coordinator: SimulatorPaneCoordinator,
        onRequestPanelFocus: @escaping @MainActor () -> Void = {}
    ) {
        self.coordinator = coordinator
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
                    onRequestPanelFocus: onRequestPanelFocus
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if coordinator.showsTools {
                    Divider()
                    SimulatorToolsPanel(coordinator: coordinator)
                        .frame(width: 270)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await coordinator.start()
        }
    }
}
