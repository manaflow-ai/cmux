import SwiftUI

extension MachinesPanelView {
    /// The panel replaces its cached tree as soon as a team mutation starts;
    /// waiting for the scope observer would leave the previous team's rows
    /// visible while the create or switch is still in flight.
    var isTeamChangePending: Bool {
        accountFlow?.isSelectingTeam == true
            || accountFlow?.isCreatingTeam == true
            || viewModel.awaitingCatalogScope
    }

    var teamScopeLoadingLabel: String {
        if accountFlow?.isCreatingTeam == true {
            return String(localized: "cloud.teamPicker.creating", defaultValue: "Creating team…")
        }
        return String(localized: "cloud.teamPicker.switching", defaultValue: "Switching teams…")
    }

    var teamScopeLoading: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(teamScopeLoadingLabel)
                .cmuxFont(size: 12)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("CloudMachinesTeamLoading")
    }
}
