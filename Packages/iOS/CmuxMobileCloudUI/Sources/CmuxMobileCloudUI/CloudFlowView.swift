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

/// A remote workspace projected from a Cloud machine. The machine id and
/// workspace id are retained together so navigation never routes through Mac.
public struct CloudWorkspaceRoute: Hashable, Sendable {
    public var machine: CloudMachine
    public var workspace: CloudWorkspaceSummary

    public init(machine: CloudMachine, workspace: CloudWorkspaceSummary) {
        self.machine = machine
        self.workspace = workspace
    }
}

/// The Cloud tab's navigation stack: machines, workspaces, and terminals.
/// The authenticated shell owns the connection lifetime, so changing tabs
/// preserves both this stack's path and its live connections.
public struct CloudFlowView: View {
    private let controller: CloudSessionController
    @State private var path = NavigationPath()
    @AppStorage("mobile.cloud.onboarding.completed.v2") private var cloudOnboardingCompleted = false
    @State private var showsCloudOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    /// Creates the flow over the app's session controller.
    public init(controller: CloudSessionController) {
        self.controller = controller
    }

    public var body: some View {
        NavigationStack(path: $path) {
            if cloudOnboardingCompleted {
                CloudSectionView(controller: controller)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L10n.string("mobile.cloud.onboarding.title", defaultValue: "Cloud basics")) {
                                showsCloudOnboarding = true
                            }
                            .accessibilityIdentifier("CloudBasicsButton")
                        }
                    }
            } else {
                CloudOnboardingView(
                    controller: controller,
                    onComplete: { cloudOnboardingCompleted = true },
                    showsNavigationChrome: false
                )
                .accessibilityIdentifier("CloudInlineOnboarding")
            }
            .navigationDestination(for: CloudMachine.self) { machine in
                CloudTerminalCatalogView(machine: machine, controller: controller)
            }
            .navigationDestination(for: CloudTerminalRoute.self) { route in
                CloudTerminalScreen(machine: route.machine, terminal: route.terminal, controller: controller)
            }
            .navigationDestination(for: CloudWorkspaceRoute.self) { route in
                CloudWorkspaceDetailView(machine: route.machine, workspace: route.workspace, controller: controller)
            }
        }
        .task { await controller.systemVPN?.refresh() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await controller.systemVPN?.refresh() }
            case .background:
                break
            default: break
            }
        }
        .sheet(isPresented: $showsCloudOnboarding) {
            CloudOnboardingView(controller: controller)
        }
    }
}
#endif
