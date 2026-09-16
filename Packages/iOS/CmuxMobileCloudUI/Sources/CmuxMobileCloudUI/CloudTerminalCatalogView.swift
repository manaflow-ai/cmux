#if os(iOS)
public import CmuxMobileCloud
import CmuxMobileSupport
import SwiftUI

/// A machine's terminals, with a New terminal action. Tapping one opens the
/// terminal screen.
///
/// HIG: Lists and tables, Loading, Navigation. The link opens lazily on first
/// load, so the connecting state shows the same progress affordance.
struct CloudTerminalCatalogView: View {
    let machine: CloudMachine
    let controller: CloudSessionController
    /// Resolved in `.task`, after the push has settled, so no observable state
    /// mutates while the navigation stack is evaluating its body.
    @State private var connection: CloudMachineConnection?

    var body: some View {
        Group {
            if let connection {
                CloudTerminalCatalogContent(connection: connection)
            } else if case .ready = controller.tunnel {
                ProgressView()
                    .accessibilityIdentifier("CloudCatalogResolving")
            } else {
                CloudTunnelUnavailableView()
            }
        }
        .navigationTitle(machine.preferredName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: CloudTerminalRoute.self) { route in
            CloudTerminalScreen(machine: route.machine, terminal: route.terminal, controller: controller)
        }
        .navigationDestination(for: CloudWorkspaceRoute.self) { route in
            CloudWorkspaceDetailView(machine: route.machine, workspace: route.workspace, controller: controller)
        }
        .task(id: controller.tunnel) {
            if connection == nil { connection = controller.connection(for: machine) }
        }
    }
}

/// The catalog list for a resolved connection.
struct CloudTerminalCatalogContent: View {
    @State var connection: CloudMachineConnection
    var workspaceID: String? = nil

    var body: some View {
        List {
            switch connection.terminals {
            case .idle, .loading where connection.terminals.elements.isEmpty:
                Section { loadingRow }
            case .failed(let failure, let previous) where previous.isEmpty:
                Section { CloudFailureRow(failure: failure, retry: { connection.refreshTerminals() }) }
            default:
                terminalsSection
            }
            workspacesSection
            createSection
        }
        .listStyle(.insetGrouped)
        .task { connection.refreshTerminals() }
        .refreshable { connection.refreshTerminals() }
    }

    private var terminalsSection: some View {
        Section {
            let terminals = connection.terminals.elements.filter { terminal in
                guard let workspaceID else { return true }
                return terminal.workspaceID == workspaceID
            }
            if terminals.isEmpty {
                Text(L10n.string("mobile.cloud.terminals.empty", defaultValue: "No terminals yet. Create one below."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(terminals) { terminal in
                    NavigationLink(value: CloudTerminalRoute(machine: connection.machine, terminal: terminal)) {
                        Text(terminal.name ?? terminal.id)
                    }
                }
            }
        } header: {
            Text(L10n.string("mobile.cloud.terminals.header", defaultValue: "Terminals"))
        }
    }

    private var workspacesSection: some View {
        Section {
            let workspaces = connection.workspaces.elements
            if workspaces.isEmpty {
                Text(L10n.string("mobile.cloud.workspaces.empty", defaultValue: "No remote workspaces yet."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(workspaces) { workspace in
                    NavigationLink(value: CloudWorkspaceRoute(machine: connection.machine, workspace: workspace)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.preferredName)
                            if let root = workspace.root {
                                Text(root).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Button {
                Task { await connection.createWorkspace() }
            } label: {
                HStack {
                    Label(L10n.string("mobile.cloud.workspaces.new", defaultValue: "New remote workspace"), systemImage: "plus")
                    if connection.isCreatingWorkspace { Spacer(); ProgressView() }
                }
            }
            .disabled(connection.isCreatingWorkspace)
        } header: {
            Text(L10n.string("mobile.cloud.workspaces.header", defaultValue: "Remote workspaces"))
        }
    }

    private var createSection: some View {
        Section {
            Button {
                Task { await connection.createTerminal() }
            } label: {
                HStack {
                    Label(L10n.string("mobile.cloud.terminals.new", defaultValue: "New terminal"), systemImage: "plus")
                    if connection.isCreatingTerminal {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(connection.isCreatingTerminal)
            .accessibilityIdentifier("CloudNewTerminalButton")
            if let failure = connection.lastError {
                Text(failure.localizedMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(failure.detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("CloudCreateFailureDetail")
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(L10n.string("mobile.cloud.terminals.loading", defaultValue: "Connecting"))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("CloudTerminalsLoading")
    }
}

/// Workspace detail uses the same terminal surface as the machine catalog,
/// while retaining the remote workspace identity for direct VM operations.
struct CloudWorkspaceDetailView: View {
    let machine: CloudMachine
    let workspace: CloudWorkspaceSummary
    let controller: CloudSessionController
    @State private var connection: CloudMachineConnection?

    var body: some View {
        Group {
            if let connection {
                CloudTerminalCatalogContent(connection: connection, workspaceID: workspace.id)
            } else if case .ready = controller.tunnel {
                ProgressView()
            } else {
                CloudTunnelUnavailableView()
            }
        }
        .navigationTitle(workspace.preferredName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: controller.tunnel) {
            if connection == nil { connection = controller.connection(for: machine) }
        }
    }
}

/// The shared workspace-list picker surface when a Cloud machine is selected
/// in the shell's computer picker. It keeps the same terminal and workspace
/// rows as the machine detail, while the VM identity remains direct.
public struct CloudWorkspacePickerList: View {
    let machine: CloudMachine
    let controller: CloudSessionController
    @State private var connection: CloudMachineConnection?

    public init(machine: CloudMachine, controller: CloudSessionController) {
        self.machine = machine
        self.controller = controller
    }

    public var body: some View {
        Group {
            if let connection {
                CloudTerminalCatalogContent(connection: connection)
            } else if case .ready = controller.tunnel {
                ProgressView()
            } else {
                CloudTunnelUnavailableView()
            }
        }
        .navigationTitle(machine.preferredName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: controller.tunnel) {
            if connection == nil { connection = controller.connection(for: machine) }
        }
    }
}
#endif
