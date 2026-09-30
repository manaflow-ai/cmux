import SwiftUI

extension MachinesPanelView {
    @ViewBuilder
    var content: some View {
        VStack(spacing: 0) {
            Group {
                // Show the empty state exactly when the outline would render zero
                // rows. The builder owns that decision (the tree is cloud-only while
                // `includesLocalMachine` is off); deciding it here from the raw
                // catalog previously left a blank panel for a signed-in account with
                // no machines, because the catalog's This Mac entry counted as a row
                // the tree never drew.
                if includesCloud && includesDevices && viewModel.visibleMachines.isEmpty, let status = viewModel.listStatus {
                    VStack(spacing: 0) {
                        MachinesListStatusNotice(status: status, perform: performListStatusAction)
                        machinesList
                    }
                } else if CloudTreeNodeBuilder.isEmpty(
                    machines: includesCloud ? viewModel.visibleMachines : [],
                    pendingCreates: includesCloud ? viewModel.pendingCreates : [],
                    snapshot: treeSnapshot,
                    source: treeSource
                ) {
                    emptyState
                } else {
                    machinesList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if includesCloud {
                CoderouterAccountsPanel(
                    teamID: accountFlow?.confirmedTeamID,
                    chromeBackgroundColor: chromeBackgroundColor
                )
                .frame(maxHeight: 270)
            }
        }
    }
}
