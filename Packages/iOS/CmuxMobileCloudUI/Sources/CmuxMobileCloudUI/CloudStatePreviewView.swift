#if os(iOS)
import CmuxMobileCloud
import CmuxMobileSupport
import SwiftUI

/// Deterministic DEBUG-only host used to review the Cloud access states in a
/// simulator without an account or a live control plane.
public struct CloudStatePreviewView: View {
    private enum State: String {
        case requiresPlan = "requires-plan"
        case available
        case machines
        case limitReached = "limit-reached"
        case unavailable

        init(rawValue: String?) {
            self = State(rawValue: rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "") ?? .requiresPlan
        }
    }

    private let state: State

    /// Creates a deterministic Cloud tab state for screenshot review.
    public init(state: String? = nil) {
        self.state = State(rawValue: state)
    }

    public var body: some View {
        NavigationStack {
            List {
                switch state {
                case .requiresPlan:
                    unavailableEmptyState
                    CloudAccessStateView(
                        access: .requiresPlan,
                        activeMachineCount: 0,
                        maxActiveMachines: 0,
                        onUpgrade: {}
                    )
                case .available:
                    emptyState
                    CloudAccessStateView(
                        access: .available,
                        activeMachineCount: 0,
                        maxActiveMachines: 5,
                        onUpgrade: {}
                    )
                    createButton
                case .machines:
                    machineRows
                    CloudAccessStateView(
                        access: .available,
                        activeMachineCount: 2,
                        maxActiveMachines: 5,
                        onUpgrade: {}
                    )
                    createButton
                case .limitReached:
                    machineRows
                    CloudAccessStateView(
                        access: .limitReached,
                        activeMachineCount: 5,
                        maxActiveMachines: 5,
                        onUpgrade: {}
                    )
                case .unavailable:
                    unavailableEmptyState
                    CloudAccessStateView(
                        access: .unavailable,
                        activeMachineCount: nil,
                        maxActiveMachines: nil,
                        onUpgrade: {}
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.string("mobile.cloud.title", defaultValue: "Cloud"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var emptyState: some View {
        Section {
            Text(L10n.string(
                "mobile.cloud.empty.create",
                defaultValue: "No Cloud machines yet. Create one below."
            ))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("CloudMachinesEmpty")
        }
    }

    private var unavailableEmptyState: some View {
        Section {
            Text(L10n.string(
                "mobile.cloud.empty.unavailable",
                defaultValue: "Cloud machine creation is unavailable for this account."
            ))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("CloudMachinesUnavailableEmpty")
        }
    }

    private var createButton: some View {
        Section {
            Label(
                L10n.string("mobile.cloud.machines.new", defaultValue: "New cloud machine"),
                systemImage: "plus"
            )
            .foregroundStyle(.tint)
            .accessibilityIdentifier("CloudCreateMachineButton")
        }
    }

    private var machineRows: some View {
        Section {
            CloudMachineRow(
                machine: CloudMachine(
                    id: "cloud-dev",
                    provider: "freestyle",
                    status: "running",
                    displayName: "Development"
                ),
                isBusy: false,
                failure: nil,
                connectionFailure: nil,
                retryConnection: {},
                pause: {},
                resume: {},
                delete: {}
            )
            CloudMachineRow(
                machine: CloudMachine(
                    id: "cloud-staging",
                    provider: "freestyle",
                    status: "paused",
                    displayName: "Staging"
                ),
                isBusy: false,
                failure: nil,
                connectionFailure: nil,
                retryConnection: {},
                pause: {},
                resume: {},
                delete: {}
            )
        } header: {
            Text(L10n.string("mobile.cloud.machines.header", defaultValue: "Machines"))
        } footer: {
            Text(L10n.string(
                "mobile.cloud.machines.footer",
                defaultValue: "Cloud machines appear in your computers, and their workspaces open in the Workspaces tab."
            ))
        }
    }
}
#endif
