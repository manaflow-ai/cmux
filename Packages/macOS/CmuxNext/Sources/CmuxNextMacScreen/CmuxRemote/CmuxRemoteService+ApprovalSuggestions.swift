// SPDX-License-Identifier: GPL-3.0-or-later
public import CmuxNextActions

/// The saved Computer Use approvals as the `appId` pick of Forget and Change a Computer Use
/// Approval (the catalog's `computerUseApprovals` source): one row per app, by app id, with its
/// current answer (the catalog's Always Allow / Never) below. The list lives in cmux Remote's
/// Computer Use worker, so each pick reads it again first, under the palette's loading state.
extension CmuxRemoteService {
    static let approvalSuggestionSource = "computerUseApprovals"

    /// Answers `computerUseApprovals` in `registry`; any other source goes to the ones bound before.
    public func bindApprovalSuggestions(into registry: ActionRegistry) {
        let previous = registry.argumentSuggestions
        registry.argumentSuggestions = { [weak self, weak registry] source in
            guard source == Self.approvalSuggestionSource else { return previous?(source) ?? [] }
            return Self.approvalChoices(self?.computerUse.approvals ?? [], decisions: Self.decisionTitles(registry))
        }
        let previousLoad = registry.argumentSuggestionsLoad
        registry.argumentSuggestionsLoad = { [weak self, weak registry] source in
            guard source == Self.approvalSuggestionSource else { return previousLoad?(source) }
            guard let self else { return nil }
            let decisions = Self.decisionTitles(registry)
            return {
                await self.refreshComputerUseApprovals()
                return Self.approvalChoices(self.computerUse.approvals, decisions: decisions)
            }
        }
    }

    /// One row per saved approval, in the worker's order (by app id).
    static func approvalChoices(_ approvals: [(appID: String, decision: String)], decisions: [String: String]) -> [ActionEnumCase] {
        approvals.map { ActionEnumCase(value: $0.appID, title: $0.appID, subtitle: decisions[$0.decision] ?? $0.decision) }
    }

    /// The catalog's titles of Change a Computer Use Approval's `decision` cases, by value.
    static func decisionTitles(_ registry: ActionRegistry?) -> [String: String] {
        let argument = registry?.descriptor(for: "computerUse.approval.set")?.arguments.first { $0.name == "decision" }
        guard case .enumeration(let cases)? = argument?.kind else { return [:] }
        return Dictionary(cases.map { ($0.value, $0.title) }, uniquingKeysWith: { first, _ in first })
    }
}
