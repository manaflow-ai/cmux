#if os(iOS)
public import CmuxMobileCloud
import CmuxMobileSupport
import SwiftUI

/// The Cloud section: the account's Cloud VMs, reachable over the phone's
/// in-process WireGuard tunnel. Tapping a machine opens its terminal catalog.
///
/// HIG: Lists and tables (inset-grouped list of machines), Loading (a progress
/// row while the tunnel comes up and the list loads), and Navigation (a stack
/// pushing catalog then terminal). See the PR description for the pages read.
///
/// The tunnel's lifecycle is owned by ``CloudSessionController`` and driven by
/// this view's appearance and the scene phase, per decision 5A.
public struct CloudSectionView: View {
    @State private var controller: CloudSessionController
    @Environment(\.scenePhase) private var scenePhase

    /// Creates the section over a session controller.
    public init(controller: CloudSessionController) {
        _controller = State(initialValue: controller)
    }

    public var body: some View {
        List {
            tunnelSection
            machinesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.string("mobile.cloud.title", defaultValue: "Cloud"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { controller.refreshMachines() }
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

    @ViewBuilder
    private var tunnelSection: some View {
        switch controller.tunnel {
        case .idle, .starting:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.string("mobile.cloud.tunnel.connecting", defaultValue: "Connecting to your private network"))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("CloudTunnelConnecting")
            }
        case .ready:
            EmptyView()
        case .failed(let failure):
            Section {
                CloudFailureRow(failure: failure, retry: { controller.retryTunnel() })
            }
        }
    }

    @ViewBuilder
    private var machinesSection: some View {
        switch controller.tunnel {
        case .ready:
            let machines = controller.machines.elements
            if machines.isEmpty, controller.machines.isLoading {
                Section { loadingRow }
            } else if machines.isEmpty {
                Section {
                    Text(L10n.string("mobile.cloud.empty", defaultValue: "No cloud machines yet. Create one from cmux on your Mac or the web app."))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CloudMachinesEmpty")
                }
            } else {
                Section {
                    ForEach(machines) { machine in
                        NavigationLink(value: machine) {
                            CloudMachineRow(machine: machine)
                        }
                    }
                } header: {
                    Text(L10n.string("mobile.cloud.machines.header", defaultValue: "Machines"))
                }
                if case .failed(let failure, _) = controller.machines {
                    Section { CloudFailureRow(failure: failure, retry: { controller.refreshMachines() }) }
                }
            }
        default:
            EmptyView()
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(L10n.string("mobile.cloud.machines.loading", defaultValue: "Loading machines"))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("CloudMachinesLoading")
    }
}

/// One machine row: its name and a lowercased status line.
struct CloudMachineRow: View {
    let machine: CloudMachine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(machine.preferredName)
                .font(.body)
            Text(machine.status.lowercased())
                .font(.caption)
                .foregroundStyle(machine.isRunning ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("CloudMachineRow")
    }
}

/// A failure row with a localized message and a Retry button.
struct CloudFailureRow: View {
    let failure: CloudSessionFailure
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CloudFailureCopy.message(for: failure))
                .foregroundStyle(.secondary)
            Button(L10n.string("mobile.cloud.retry", defaultValue: "Retry"), action: retry)
                .buttonStyle(.bordered)
        }
        .accessibilityIdentifier("CloudFailureRow")
    }
}

/// The push target when a machine's tunnel is not ready.
struct CloudTunnelUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            L10n.string("mobile.cloud.unavailable.title", defaultValue: "Not connected"),
            systemImage: "network.slash",
            description: Text(L10n.string("mobile.cloud.unavailable.body", defaultValue: "The private network is not up yet. Go back and try again."))
        )
    }
}

/// Localized copy for each failure kind.
enum CloudFailureCopy {
    static func message(for failure: CloudSessionFailure) -> String {
        switch failure.kind {
        case .signedOut:
            return L10n.string("mobile.cloud.error.signedOut", defaultValue: "Your session expired. Sign in again to reach your cloud machines.")
        case .controlPlane:
            return L10n.string("mobile.cloud.error.controlPlane", defaultValue: "The cloud service could not be reached. Try again in a moment.")
        case .tunnel:
            return L10n.string("mobile.cloud.error.tunnel", defaultValue: "Could not join your private network. Check your connection and try again.")
        case .link:
            return L10n.string("mobile.cloud.error.link", defaultValue: "Could not reach this machine's terminal service.")
        case .identity:
            return L10n.string("mobile.cloud.error.identity", defaultValue: "This device is locked. Unlock it and try again.")
        case .other:
            return L10n.string("mobile.cloud.error.other", defaultValue: "Something went wrong. Try again.")
        }
    }
}
#endif
