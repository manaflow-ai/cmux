import CmuxCloud
import CmuxSettingsUI
import Foundation

/// Cloud Settings routes through the app's shared presenters.
extension HostSettingsActions {
    var isCloudMachinesAvailable: Bool {
        CloudMachinesFeature.isAvailable
    }
    var isCloudMachinesEnabled: Bool {
        CloudMachinesFeature.isEnabled
    }
    var cloudMachinesActivationState: CloudMachinesActivationState {
        Self.settingsActivationState(from: cloudActivationCoordinator?.state)
    }

    func enableCloudMachines() {
        cloudActivationCoordinator?.enable()
    }

    func cancelCloudMachinesActivation() {
        cloudActivationCoordinator?.cancel()
    }

    func retryCloudMachinesActivation() {
        cloudActivationCoordinator?.retry()
    }

    func disableCloudMachines() {
        cloudActivationCoordinator?.disable()
    }

    func cloudMachinesActivationUpdates() -> AsyncStream<CloudMachinesActivationState> {
        guard let coordinator = cloudActivationCoordinator else {
            return AsyncStream { $0.yield(.unavailable); $0.finish() }
        }
        return AsyncStream { continuation in
            let source = coordinator.activationChanges()
            let task = Task { @MainActor in
                for await state in source {
                    guard !Task.isCancelled else { break }
                    continuation.yield(Self.settingsActivationState(from: state))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func signInForCloudMachines() {
        AppDelegate.shared?.auth?.accountFlow.startSignIn()
    }

    func cloudMachinesPlanSummary() async -> CloudMachinesPlanSummary? {
        guard CloudMachinesFeature.isEnabled else { return nil }
        guard let client = VMClient.shared else { return nil }
        guard let page = try? await client.listPage(), let limits = page.limits else { return nil }
        // Same classifier as the Machines panel so Settings and the panel never
        // disagree about an unknown plan id (both fail closed to "not paid").
        let isPaid = MachinePlanSnapshot.isPaidPlanID(limits.planId)
        let planLabel = isPaid
            ? limits.planId.capitalized
            : String(localized: "settings.cloudMachines.plan.free", defaultValue: "Free")
        return CloudMachinesPlanSummary(
            planLabel: planLabel,
            activeMachines: page.vms.count,
            maxMachines: limits.maxActiveVms,
            isPaidPlan: isPaid
        )
    }

    var cloudMachinesAccountID: String? {
        guard let flow = AppDelegate.shared?.auth?.accountFlow,
              let accountID = flow.currentIdentity?.id else { return nil }
        // Include the active team so a team switch reruns entitlement lookup
        // even though the signed-in account remains unchanged.
        let teamID = flow.confirmedTeamID ?? "personal"
        return "\(accountID):\(teamID)"
    }

    func cloudMachinesPlanIncludesCloud() async -> Bool? {
        guard let flow = AppDelegate.shared?.auth?.accountFlow, flow.isAuthenticated,
              let accountID = flow.currentIdentity?.id else { return nil }
        let requestedTeamID = flow.confirmedTeamID
        guard await flow.refreshBillingPlanAndReportSuccess() else { return nil }
        // Only answer for the account that asked; a switch mid-check means
        // this answer belongs to someone else.
        guard !Task.isCancelled,
              flow.currentIdentity?.id == accountID,
              flow.confirmedTeamID == requestedTeamID else { return nil }
        // Same answer the Cloud tab uses, so both show Upgrade for Free plans.
        return flow.hasLoadedBillingPlan ? flow.isProActive : nil
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

    private static func settingsActivationState(
        from state: CloudActivationCoordinator.State?
    ) -> CloudMachinesActivationState {
        guard let state else { return .unavailable }
        switch state {
        case .disabled: return .disabled
        case .enabling: return .enabling
        case .enabled: return .enabled
        case .cancelled: return .cancelled
        case .unavailable: return .unavailable
        case .failed(let failure):
            switch failure {
            case .requiresPro: return .failed(.requiresPro)
            case .signInRequired: return .failed(.signInRequired)
            case .serviceUnavailable: return .failed(.serviceUnavailable)
            }
        }
    }
}
