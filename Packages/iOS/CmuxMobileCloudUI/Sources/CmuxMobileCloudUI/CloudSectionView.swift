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
/// the enclosing ``CloudFlowView``'s appearance and the scene phase (5A).
public struct CloudSectionView: View {
    @State private var controller: CloudSessionController
    @State private var isCreateSheetPresented = false

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
        .sheet(isPresented: $isCreateSheetPresented) {
            CloudCreateMachineSheet(controller: controller)
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
                    Text(L10n.string("mobile.cloud.empty", defaultValue: "No cloud machines yet."))
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
            createMachineSection
        default:
            EmptyView()
        }
    }

    private var createMachineSection: some View {
        Section {
            Button {
                isCreateSheetPresented = true
            } label: {
                Label(
                    L10n.string("mobile.cloud.machines.new", defaultValue: "New cloud machine"),
                    systemImage: "plus"
                )
            }
            .accessibilityIdentifier("CloudCreateMachineButton")
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

/// A small create form. The backend remains the source of truth for team,
/// provider, image, and billing checks; the phone only chooses the machine
/// shape and sends the request when the user confirms.
struct CloudCreateMachineSheet: View {
    let controller: CloudSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var kind: CloudMachineKind = .base

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(
                        L10n.string("mobile.cloud.create.kind", defaultValue: "Type"),
                        selection: $kind
                    ) {
                        ForEach(CloudMachineKind.allCases, id: \.self) { kind in
                            Text(kindTitle(kind)).tag(kind)
                        }
                    }
                    .accessibilityIdentifier("CloudCreateMachineKind")
                    Text(kindDescription(kind))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task {
                            let created = await controller.createMachine(options: .init(kind: kind))
                            if created != nil { dismiss() }
                        }
                    } label: {
                        HStack {
                            Text(L10n.string("mobile.cloud.create.submit", defaultValue: "Create machine"))
                            if controller.isCreatingMachine {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(controller.isCreatingMachine)
                    .accessibilityIdentifier("CloudCreateMachineSubmit")

                    if let failure = controller.lastCreateFailure {
                        Text(failure.localizedMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(failure.detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("CloudCreateMachineFailure")
                    }
                } footer: {
                    Text(L10n.string(
                        "mobile.cloud.create.wait",
                        defaultValue: "Provisioning can take a few minutes. You can leave this screen and check the machine list later."
                    ))
                }
            }
            .navigationTitle(L10n.string("mobile.cloud.create.title", defaultValue: "New cloud machine"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.cloud.cancel", defaultValue: "Cancel")) { dismiss() }
                        .disabled(controller.isCreatingMachine)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func kindTitle(_ kind: CloudMachineKind) -> String {
        switch kind {
        case .base: return L10n.string("mobile.cloud.create.base", defaultValue: "Base, terminal only")
        case .desktop: return L10n.string("mobile.cloud.create.desktop", defaultValue: "Desktop, terminal plus screen")
        }
    }

    private func kindDescription(_ kind: CloudMachineKind) -> String {
        switch kind {
        case .base: return L10n.string("mobile.cloud.create.base.description", defaultValue: "Starts faster and uses less memory.")
        case .desktop: return L10n.string("mobile.cloud.create.desktop.description", defaultValue: "Includes a desktop for GUI apps and browser work.")
        }
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
            Text(failure.localizedMessage)
                .foregroundStyle(.secondary)
            // The underlying error, so a dogfooder can report the exact cause.
            Text(failure.detail)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .accessibilityIdentifier("CloudFailureDetail")
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
extension CloudSessionFailure {
    var localizedMessage: String {
        switch kind {
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
