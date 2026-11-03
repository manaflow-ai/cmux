// Catalog rows for one domain. Titles live in ActionCatalog.xcstrings.

/// Computer Use app approvals (docs/computer-use-approvals.md, Controls): the saved approvals of
/// this cmux client and the status. The CLI and MCP also reach them through the app socket
/// (`computer_use.approvals.*`, `computer_use.status`).
nonisolated enum ComputerUseApprovalActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "computerUse.revokeSavedApprovals",
                title: String(localized: "action.computerUse.revokeSavedApprovals", defaultValue: "Computer Use: Revoke Saved App Approvals…", bundle: .module),
                keywords: ["computer use", "approval", "approvals", "revoke", "always allow", "apps", "agents", "permission"],
                category: .tab, symbol: "hand.raised.slash", surfaces: [.palette],
                cliName: "computer-use revoke-saved-approvals",
                surfacePlan: ActionSurfacePlan(contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "computerUse.showStatus",
                title: String(localized: "action.computerUse.showStatus", defaultValue: "Computer Use: Show Status", bundle: .module),
                keywords: ["computer use", "status", "approvals", "mode", "agents", "apps", "pending"],
                category: .tab, symbol: "cursorarrow.rays", surfaces: [.palette],
                cliName: "computer-use show-status",
                surfacePlan: ActionSurfacePlan(contextMenuExemption: .noObject)
            ),
        ]
    }
}
