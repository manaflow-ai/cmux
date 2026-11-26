import Foundation

/// The paid-plan welcome card (plans/cmux-next/paid-plans-DESIGN.md §2, gap 2): each plan the app reads goes
/// through ``PaidPlanOnboarding``; its one welcome becomes a sidebar card whose main button starts a Cloud workspace.
@MainActor
package struct PaidPlanWelcome {
    package var onboarding: PaidPlanOnboarding
    /// The signed-in account id; nil shows nothing.
    package var account: @MainActor () -> String?
    /// Shows the card (title, detail, main button, second button); true for the main button.
    package var ask: @MainActor (_ title: String, _ detail: String, _ yes: String, _ no: String) async -> Bool
    package var startCloudWorkspace: @MainActor () -> Void

    package init(onboarding: PaidPlanOnboarding, account: @escaping @MainActor () -> String?,
                 ask: @escaping @MainActor (String, String, String, String) async -> Bool, startCloudWorkspace: @escaping @MainActor () -> Void) {
        self.onboarding = onboarding
        self.account = account
        self.ask = ask
        self.startCloudWorkspace = startCloudWorkspace
    }

    /// The card for `planID` if the plan just turned paid after an upgrade; returns the task that shows it.
    @discardableResult
    package func planObserved(_ planID: String?) -> Task<Void, Never>? {
        guard let account = account(), let welcome = onboarding.observe(planID: planID, account: account) else { return nil }
        let ask = ask, start = startCloudWorkspace
        // task-owner: one welcome card; ends when the person answers it
        return Task { @MainActor in
            if await ask(BillingStrings.welcomeTitle(welcome.plan), BillingStrings.welcomeDetail, BillingStrings.welcomeStart, BillingStrings.welcomeLater) { start() }
        }
    }
}
