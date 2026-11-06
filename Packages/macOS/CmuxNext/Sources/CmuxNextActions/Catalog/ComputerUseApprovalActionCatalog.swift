// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Computer Use › Saved Approvals: forget an app's remembered answer, or change it to
// Always Allow or Never. The person's own choices: the Settings page and the CLI run them; the app
// sends them to cmux Remote's Computer Use worker through the daemon (`computer-use-approvals`).
// Titles live in ComputerUseActions.xcstrings.

nonisolated enum ComputerUseApprovalActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let plan = ActionSurfacePlan(palette: .exempt(.noObject), cli: .offered, contextMenuExemption: .noObject)
        let app = ActionArgument(name: "app_id", title: t("argument.computerUse.approval.appID", "App"), kind: .string)
        let forget = ActionDescriptor(
            id: "computerUse.approval.forget", title: t("action.computerUse.approval.forget", "Forget a Computer Use Approval"),
            keywords: ["computer use", "approval", "forget", "app", "agent"], category: .agents, symbol: "xmark.circle",
            surfaces: [.keyboard], arguments: [app], cliName: "agent forget-computer-use-approval", surfacePlan: plan)
        let set = ActionDescriptor(
            id: "computerUse.approval.set", title: t("action.computerUse.approval.set", "Change a Computer Use Approval"),
            keywords: ["computer use", "approval", "always", "never", "app", "agent"], category: .agents, symbol: "checkmark.circle",
            surfaces: [.keyboard],
            arguments: [app, ActionArgument(name: "decision", title: t("argument.computerUse.approval.decision", "Always or Never"), kind: .string)],
            cliName: "agent set-computer-use-approval", surfacePlan: plan)
        return [forget, set]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "ComputerUseActions", bundle: .module)
    }
}
