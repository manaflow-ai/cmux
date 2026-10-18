import CmuxCloud
import CmuxCloudBannerCore
import SwiftUI

/// Binds ``CloudGettingStartedCard`` to the Machines panel.
///
/// Reads the panel model, the shared banner dismissals and the secrets bridge
/// in its own body, so their changes redraw only the card. Every step reads
/// the source the panel already shows: the machine rows and header count of
/// the Cloud Machines section, and the tree's terminal failure predicate.
/// Every button goes through a path the panel already uses: the New Cloud
/// Machine action (the same gates and sheet as Cmd-Shift-Y), the Cloud agent
/// launcher, and the Cloud Secrets sheet the bridge publishes.
struct CloudGettingStartedPanelSection: View {
    @ObservedObject var viewModel: MachinesPanelViewModel
    let tabManager: TabManager?
    let dismissals: CloudBannerDismissalStore
    var bridge: CloudGettingStartedSecretsBridge = .shared

    /// Whether this mount has made its once-per-open retirement decision.
    /// Taken at the first settled read, not at appear, because the machine
    /// list may still be loading when the panel opens.
    @State private var hasSettledThisOpen = false

    private var isDismissed: Bool {
        dismissals.isDismissed(
            id: CloudGettingStartedChecklist.dismissalID,
            signature: CloudGettingStartedChecklist.dismissalSignature
        )
    }

    private var hasSeenCompletion: Bool {
        dismissals.isDismissed(
            id: CloudGettingStartedChecklist.completionSeenID,
            signature: CloudGettingStartedChecklist.dismissalSignature
        )
    }

    private var machineCount: Int {
        let listed = MachineSnapshotBuilder.includingCatalogMachines(
            viewModel.visibleMachines, catalog: viewModel.visibleCatalog
        )
        return CloudGettingStartedChecklist.machineCount(
            listedMachines: listed.count,
            headerActiveCount: viewModel.visibleUsage?.activeCount,
            creatingCount: viewModel.pendingCreates.count(where: { $0.isRunning || $0.isReconciling })
        )
    }

    private var checklist: CloudGettingStartedChecklist {
        CloudGettingStartedChecklist(.init(
            secretCount: bridge.secretCount,
            machineCount: machineCount,
            hasCloudAgent: CloudGettingStartedChecklist.hasCloudAgent(
                in: viewModel.visibleCatalog,
                unreadFailureTerminalIDs: viewModel.unreadFailureTerminalIDs
            ),
            hasLoadedMachines: viewModel.hasLoadedOnce,
            hasListProblem: viewModel.listStatus != nil,
            isDismissed: isDismissed
        ))
    }

    var body: some View {
        let checklist = checklist
        Group {
            if checklist.isVisible {
                CloudGettingStartedCard(checklist: checklist, actions: actions)
                    .transition(.opacity)
            }
        }
        .cloudGettingStartedDebugProbe(checklist: checklist, actions: { actions })
        // The first settled read of this open: a card whose finished state
        // was already seen in an earlier panel retires now, before it draws.
        .onChange(of: viewModel.hasLoadedOnce, initial: true) { _, loaded in
            guard loaded, !hasSettledThisOpen else { return }
            hasSettledThisOpen = true
            if CloudGettingStartedChecklist.retiresOnOpen(hasSeenCompletion: hasSeenCompletion) { dismiss() }
        }
        // Closing the panel on a finished card is what "seen" means, so the
        // card never disappears mid-glance and a run that fails seconds after
        // it started does not retire the card behind the person's back.
        .onDisappear {
            if CloudGettingStartedChecklist.marksCompletionSeen(self.checklist) { markCompletionSeen() }
        }
    }

    private var actions: CloudGettingStartedActions {
        CloudGettingStartedActions(
            openSecrets: bridge.openSecrets,
            createMachine: createMachine,
            openLocalAgent: { [weak viewModel] in viewModel?.launchCloudAgent(.claude) },
            dismiss: dismiss,
            startFirstAgent: {
                CloudFirstRunPresenter.shared.present(preferredWindow: tabManager?.window)
            },
            openRepository: {
                AppDelegate.shared?.performOpenRepositoryInCloudAction(
                    agent: .claude,
                    preferredWindow: tabManager?.window,
                    debugSource: "cloud.gettingStarted"
                )
            }
        )
    }

    private func createMachine() {
        _ = AppDelegate.shared?.performNewCloudMachineAction(
            tabManager: tabManager,
            preferredWindow: tabManager?.window,
            debugSource: "cloud.gettingStarted"
        )
    }

    private func dismiss() {
        dismissals.dismiss(
            id: CloudGettingStartedChecklist.dismissalID,
            signature: CloudGettingStartedChecklist.dismissalSignature
        )
    }

    private func markCompletionSeen() {
        dismissals.dismiss(
            id: CloudGettingStartedChecklist.completionSeenID,
            signature: CloudGettingStartedChecklist.dismissalSignature
        )
    }
}
