import CmuxCloudBannerCore
import SwiftUI

/// Binds ``CloudGettingStartedCard`` to the Machines panel.
///
/// Reads the panel model, the shared banner dismissals and the secrets bridge
/// in its own body, so their changes redraw only the card. Every button goes
/// through a path the panel already uses: the New Cloud Machine action (the
/// same gates and sheet as Cmd-Shift-Y), the Cloud agent launcher, and the
/// Cloud Secrets sheet the bridge publishes.
struct CloudGettingStartedPanelSection: View {
    @ObservedObject var viewModel: MachinesPanelViewModel
    let tabManager: TabManager?
    let dismissals: CloudBannerDismissalStore
    var bridge: CloudGettingStartedSecretsBridge = .shared

    private var isDismissed: Bool {
        dismissals.isDismissed(
            id: CloudGettingStartedChecklist.dismissalID,
            signature: CloudGettingStartedChecklist.dismissalSignature
        )
    }

    private var checklist: CloudGettingStartedChecklist {
        CloudGettingStartedChecklist(.init(
            secretCount: bridge.secretCount,
            machineCount: viewModel.visibleMachines.count + viewModel.pendingCreates.count,
            hasCloudAgent: CloudGettingStartedChecklist.hasCloudAgent(in: viewModel.visibleCatalog),
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
        // Finishing every step retires the card for good, so deleting the
        // last machine later never brings the checklist back.
        .onChange(of: checklist.isComplete && viewModel.hasLoadedOnce, initial: true) { _, finished in
            if finished { dismiss() }
        }
    }

    private var actions: CloudGettingStartedActions {
        CloudGettingStartedActions(
            openSecrets: bridge.openSecrets,
            createMachine: createMachine,
            openLocalAgent: { [weak viewModel] in viewModel?.launchCloudAgent(.claude) },
            dismiss: dismiss
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
}
