import CmuxSidebar
import Foundation

extension SidebarAgentUsageFormatter.Strings {
    /// The app catalog's cost marks and tooltip (resolved once; the app
    /// language only changes across launches).
    static let localized = SidebarAgentUsageFormatter.Strings(
        // The tilde marks the figure as an estimate, the plus a lower bound.
        estimatedCost: { costText in
            String(localized: "sidebar.agentUsage.estimatedCost", defaultValue: "~\(costText)")
        },
        estimatedCostAtLeast: { costText in
            String(localized: "sidebar.agentUsage.estimatedCostAtLeast", defaultValue: "~\(costText)+")
        },
        costHelpText: String(
            localized: "sidebar.agentUsage.costHelp",
            defaultValue: "Cost is an API list-price estimate, not your subscription bill."
        )
    )
}
