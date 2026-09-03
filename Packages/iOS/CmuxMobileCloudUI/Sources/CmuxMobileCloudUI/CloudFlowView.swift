#if os(iOS)
public import CmuxMobileCloud
import CmuxMobileSupport
public import SwiftUI

/// The route to a cloud terminal: the machine it lives on plus the terminal.
public struct CloudTerminalRoute: Hashable, Sendable {
    public var machine: CloudMachine
    public var terminal: CloudTerminalSummary

    public init(machine: CloudMachine, terminal: CloudTerminalSummary) {
        self.machine = machine
        self.terminal = terminal
    }
}

/// The whole Cloud flow in its own navigation stack: section, catalog,
/// terminal. Presented full screen from ``CloudEntryRow``.
///
/// Owning the stack matters for two reasons. The tunnel lifecycle (decision
/// 5A) is tied to this container's appearance, which is stable across pushes,
/// whereas a pushed screen's `onDisappear` fires mid-transition. And the
/// destinations register at this stack's root, so a re-render of the host
/// list cannot pop them. HIG: Modality (a self-contained task presented full
/// screen), Navigation bars (a Done button closes the flow).
public struct CloudFlowView: View {
    private let controller: CloudSessionController
    @State private var path = NavigationPath()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// Creates the flow over the app's session controller.
    public init(controller: CloudSessionController) {
        self.controller = controller
    }

    public var body: some View {
        NavigationStack(path: $path) {
            CloudSectionView(controller: controller)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(L10n.string("mobile.cloud.done", defaultValue: "Done")) { dismiss() }
                            .accessibilityIdentifier("CloudDoneButton")
                    }
                }
                .navigationDestination(for: CloudMachine.self) { machine in
                    CloudTerminalCatalogView(machine: machine, controller: controller)
                }
                .navigationDestination(for: CloudTerminalRoute.self) { route in
                    CloudTerminalScreen(machine: route.machine, terminal: route.terminal, controller: controller)
                }
        }
        .onAppear { controller.sectionDidAppear() }
        .onDisappear { controller.sectionDidDisappear() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: controller.sceneWillEnterForeground()
            case .background: controller.sceneDidEnterBackground()
            default: break
            }
        }
    }
}
#endif
