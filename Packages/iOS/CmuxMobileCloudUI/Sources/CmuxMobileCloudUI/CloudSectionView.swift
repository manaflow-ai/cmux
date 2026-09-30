#if os(iOS)
public import CmuxMobileCloud
import CmuxMobileSupport
import SwiftUI

/// The Cloud tab's machine list: where machines are listed, created and
/// inspected. A machine's terminals open from the Workspaces tab alongside
/// every other computer's, so rows here do not navigate.
///
/// HIG: Lists and tables (inset-grouped list of machines) and Loading (a
/// progress row while the list loads, and while the tunnel comes up once there
/// is a machine to reach).
///
/// The tunnel's lifecycle is owned by ``CloudSessionController``, leased by
/// the composition root while the account owns a machine; this view only
/// reflects it.
public struct CloudSectionView: View {
    @State private var controller: CloudSessionController
    @Environment(\.cloudSystemVPNController) private var systemVPN
    @State private var isCreateSheetPresented = false
    /// The machine awaiting delete confirmation.
    @State private var pendingDelete: CloudMachine?

    /// Creates the section over a session controller.
    public init(controller: CloudSessionController) {
        _controller = State(initialValue: controller)
    }

    public var body: some View {
        List {
            tunnelSection
            machinesSection
            systemVPNSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.string("mobile.cloud.title", defaultValue: "Cloud"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            controller.refreshMachines()
            controller.retryConnections()
        }
        .confirmationDialog(
            pendingDelete.map {
                String(format: L10n.string("mobile.cloud.delete.titleFormat", defaultValue: "Delete %@?"), $0.preferredName)
            } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { machine in
            Button(L10n.string("mobile.cloud.action.delete", defaultValue: "Delete"), role: .destructive) {
                Task { await controller.deleteMachine(machine) }
            }
            .accessibilityIdentifier("CloudDeleteMachineConfirm")
        } message: { _ in
            Text(L10n.string(
                "mobile.cloud.delete.message",
                defaultValue: "This permanently deletes the machine and its disk, including its terminals and files."
            ))
        }
        .sheet(isPresented: $isCreateSheetPresented) {
            CloudCreateMachineSheet(
                controller: controller,
                availableKinds: controller.availableMachineKinds
            )
        }
    }

    /// The system VPN only matters once there is a machine to reach, but stays
    /// visible while it is on so it can always be turned off here.
    @ViewBuilder
    private var systemVPNSection: some View {
        if let systemVPN, !controller.machines.elements.isEmpty || systemVPN.phase != .off {
            CloudSystemVPNSection(
                phase: systemVPN.phase,
                isAvailable: systemVPN.isAvailable,
                enable: { systemVPN.enable() },
                disable: { systemVPN.disable() },
                retry: { systemVPN.retry() }
            )
        }
    }

    /// The tunnel only matters once there is a machine to reach; listing and
    /// creating machines are control-plane calls that need none. An account
    /// with no machines never starts a tunnel, so an idle tunnel is not
    /// "connecting" and shows nothing.
    @ViewBuilder
    private var tunnelSection: some View {
        if !controller.machines.elements.isEmpty {
            switch controller.tunnel {
            case .starting:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.string("mobile.cloud.tunnel.connecting", defaultValue: "Connecting to your private network"))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("CloudTunnelConnecting")
                }
            case .failed(let failure):
                Section {
                    CloudFailureRow(failure: failure, retry: { controller.retryTunnel() })
                }
            case .idle, .ready:
                EmptyView()
            }
        }
    }

    /// Rendered from the list's own phase, never the tunnel's.
    @ViewBuilder
    private var machinesSection: some View {
        let machines = controller.machines.elements
        switch controller.machines {
        case .idle, .loading where machines.isEmpty:
            Section { loadingRow }
        case .failed(let failure, _) where machines.isEmpty:
            Section { CloudFailureRow(failure: failure, retry: { controller.refreshMachines() }) }
        default:
            if machines.isEmpty {
                Section {
                    Text(L10n.string("mobile.cloud.empty.create", defaultValue: "No Cloud machines yet. Create one below."))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CloudMachinesEmpty")
                }
            } else {
                Section {
                    // Rows do not navigate: a machine's terminals live in the
                    // Workspaces tab with every other computer's, so there is
                    // no second terminal experience to push to from here.
                    ForEach(machines) { machine in
                        CloudMachineRow(
                            machine: machine,
                            isBusy: controller.machineActionsInFlight.contains(machine.id),
                            failure: controller.lastMachineActionFailure?.machineID == machine.id
                                ? controller.lastMachineActionFailure
                                : nil,
                            connectionFailure: machine.isRunning
                                ? controller.connectionFailure(for: machine.id)
                                : nil,
                            retryConnection: { controller.retryConnections() },
                            pause: { Task { await controller.pauseMachine(machine) } },
                            resume: { Task { await controller.resumeMachine(machine) } },
                            requestDelete: { pendingDelete = machine }
                        )
                    }
                } header: {
                    Text(L10n.string("mobile.cloud.machines.header", defaultValue: "Machines"))
                } footer: {
                    Text(
                        L10n.string(
                            "mobile.cloud.machines.footer",
                            defaultValue: "Cloud machines appear in your computers, and their workspaces open in the Workspaces tab."
                        )
                    )
                }
                if case .failed(let failure, _) = controller.machines {
                    Section { CloudFailureRow(failure: failure, retry: { controller.refreshMachines() }) }
                }
            }
        }
        createMachineSection
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
    let availableKinds: Set<CloudMachineKind>?
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
                    if let availableKinds, !availableKinds.contains(kind) {
                        Text(L10n.string(
                            "mobile.cloud.create.kindUnavailable",
                            defaultValue: "This type isn't available yet. Choose Base."
                        ))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
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
                    .disabled(controller.isCreatingMachine || (availableKinds.map { !$0.contains(kind) } ?? false))
                    .accessibilityIdentifier("CloudCreateMachineSubmit")

                    if let failure = controller.lastCreateFailure {
                        Text(failure.localizedMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let action = failure.action, !action.isEmpty {
                            Text(action)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                        }
                        Text(failure.detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("CloudCreateMachineFailure")
                    }
                } footer: {
                    if controller.isCreatingMachine {
                        Text(L10n.string(
                            "mobile.cloud.create.wait",
                            defaultValue: "Creating your machine. This takes a moment."
                        ))
                    }
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
    /// A pause, resume or delete is running for this machine.
    let isBusy: Bool
    /// The last lifecycle failure, when it hit this machine.
    let failure: CloudMachineActionFailure?
    /// Why the machine's terminal service could not be reached, while it is
    /// running but unreachable. The bridge keeps retrying on its own.
    let connectionFailure: CloudSessionFailure?
    let retryConnection: () -> Void
    let pause: () -> Void
    let resume: () -> Void
    let requestDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.preferredName)
                    .font(.body)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .accessibilityIdentifier("CloudMachineStatus")
                if let failure {
                    Text(failureText(failure))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("CloudMachineActionFailure")
                }
                if let connectionFailure {
                    Text(L10n.string(
                        "mobile.cloud.machine.connectFailed",
                        defaultValue: "Couldn't connect. Retrying automatically."
                    ))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("CloudMachineConnectionFailure")
                    Text(connectionReason(connectionFailure))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CloudMachineConnectionReason")
                }
            }
            Spacer(minLength: 0)
            if isBusy {
                ProgressView()
                    .accessibilityIdentifier("CloudMachineBusy")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("CloudMachineRow")
        .contextMenu { actions }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if machine.lifecycle.canDelete {
                Button(role: .destructive, action: requestDelete) {
                    Label(L10n.string("mobile.cloud.action.delete", defaultValue: "Delete"), systemImage: "trash")
                }
                .disabled(isBusy)
            }
            if machine.lifecycle.canPause {
                Button(action: pause) {
                    Label(L10n.string("mobile.cloud.action.pause", defaultValue: "Pause"), systemImage: "pause.circle")
                }
                .tint(.orange)
                .disabled(isBusy)
            }
            if machine.lifecycle.canResume {
                Button(action: resume) {
                    Label(L10n.string("mobile.cloud.action.resume", defaultValue: "Resume"), systemImage: "play.circle")
                }
                .tint(.green)
                .disabled(isBusy)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if connectionFailure != nil {
            Button(action: retryConnection) {
                Label(
                    L10n.string("mobile.cloud.action.retryNow", defaultValue: "Try Again Now"),
                    systemImage: "arrow.clockwise"
                )
            }
        }
        if machine.lifecycle.canResume {
            Button(action: resume) {
                Label(L10n.string("mobile.cloud.action.resume", defaultValue: "Resume"), systemImage: "play.circle")
            }
            .disabled(isBusy)
        }
        if machine.lifecycle.canPause {
            Button(action: pause) {
                Label(L10n.string("mobile.cloud.action.pause", defaultValue: "Pause"), systemImage: "pause.circle")
            }
            .disabled(isBusy)
        }
        if machine.lifecycle.canDelete {
            Button(role: .destructive, action: requestDelete) {
                Label(L10n.string("mobile.cloud.action.delete", defaultValue: "Delete"), systemImage: "trash")
            }
            .disabled(isBusy)
        }
    }

    private var statusText: String {
        switch machine.lifecycle {
        case .running: return L10n.string("mobile.cloud.status.running", defaultValue: "Running")
        case .paused: return L10n.string("mobile.cloud.status.paused", defaultValue: "Paused")
        case .provisioning: return L10n.string("mobile.cloud.status.provisioning", defaultValue: "Starting")
        case .failed: return L10n.string("mobile.cloud.status.failed", defaultValue: "Failed")
        // Destroyed machines are filtered out before they reach a screen; a
        // state this build does not know yet shows the server's own word.
        case .destroyed, .unknown: return machine.status
        }
    }

    private var statusColor: Color {
        switch machine.lifecycle {
        case .running: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    /// The control plane writes its own user-facing reason for an attach it
    /// refused; anything else gets the local copy for its kind.
    private func connectionReason(_ failure: CloudSessionFailure) -> String {
        guard case .controlPlane = failure.kind else { return failure.localizedMessage }
        return [failure.detail, failure.action ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func failureText(_ failure: CloudMachineActionFailure) -> String {
        let format: String
        switch failure.action {
        case .pause: format = L10n.string("mobile.cloud.action.pauseFailedFormat", defaultValue: "Couldn't pause: %@")
        case .resume: format = L10n.string("mobile.cloud.action.resumeFailedFormat", defaultValue: "Couldn't resume: %@")
        case .delete: format = L10n.string("mobile.cloud.action.deleteFailedFormat", defaultValue: "Couldn't delete: %@")
        }
        return String(format: format, failure.failure.action ?? failure.failure.detail)
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
            if let action = failure.action, !action.isEmpty {
                Text(action)
                    .font(.footnote)
                    .foregroundStyle(.primary)
            }
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
