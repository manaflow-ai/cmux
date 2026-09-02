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
    @State var connection: CloudMachineConnection

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
            createSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(connection.machine.preferredName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: CloudTerminalSummary.self) { terminal in
            CloudTerminalScreen(connection: connection, terminal: terminal)
        }
        .task { connection.refreshTerminals() }
        .refreshable { connection.refreshTerminals() }
    }

    private var terminalsSection: some View {
        Section {
            let terminals = connection.terminals.elements
            if terminals.isEmpty {
                Text(L10n.string("mobile.cloud.terminals.empty", defaultValue: "No terminals yet. Create one below."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(terminals) { terminal in
                    NavigationLink(value: terminal) {
                        Text(terminal.name ?? terminal.id)
                    }
                }
            }
        } header: {
            Text(L10n.string("mobile.cloud.terminals.header", defaultValue: "Terminals"))
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
                Text(CloudFailureCopy.message(for: failure))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
#endif
