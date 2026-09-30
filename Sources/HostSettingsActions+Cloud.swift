import CmuxCloud
import CmuxSettingsUI
import Foundation

/// Cloud Settings routes through the app's shared presenters.
extension HostSettingsActions {
    var isCloudMachinesAvailable: Bool {
        CloudMachinesFeature.isEnabled
    }
    func cloudMachinesPlanSummary() async -> CloudMachinesPlanSummary? {
        guard CloudMachinesFeature.isEnabled else { return nil }
        guard let client = VMClient.shared else { return nil }
        guard let page = try? await client.listPage(), let limits = page.limits else { return nil }
        // Same classifier as the Machines panel so Settings and the panel never
        // disagree about an unknown plan id (both fail closed to "not paid").
        let isPaid = MachinePlanSnapshot.isPaidPlanID(limits.planId)
        let plan = MachineSnapshotBuilder.planSnapshot(
            activeCount: page.vms.count,
            limits: limits
        )
        let planLabel = isPaid
            ? limits.planId.capitalized
            : String(localized: "settings.cloudMachines.plan.free", defaultValue: "Free")
        return CloudMachinesPlanSummary(
            planLabel: planLabel,
            activeMachines: page.vms.count,
            maxMachines: plan?.meterMaxActiveVms,
            isPaidPlan: isPaid
        )
    }

    func openCloudMachinesPanel() {
        _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(mode: .machines)
    }

    func openCloudMachinesBilling() {
        ProUpgradePresenter.present(source: .settingsCloudMachines)
    }

    func openCloudVPNSetup() {
        AppDelegate.shared?.openCloudVPNSetup(bringWindowForward: true)
    }
}
