import Foundation

/// Classifies an agent from free-form name candidates (process names, titles,
/// labels) by case-insensitive substring match and returns the matched agent's
/// brand-mark asset catalog image name.
///
/// This is the pure name->asset classifier extracted from `SessionAgent`. The
/// task-manager snapshot parser holds it as a value-typed seam
/// (`SessionAgentAssetResolver.standard`) instead of reaching into `SessionAgent`
/// statics, so the classification table is an injectable value and the parser
/// depends on a plain value rather than the agent enum's presentation surface.
/// `SessionAgent` itself stays app-side (its `.registered` case is coupled to
/// `CmuxVaultAgentRegistration`); only this pure classifier is split out.
struct SessionAgentAssetResolver: Sendable {
    /// One classification rule: a lowercased substring `token` and the
    /// `assetName` returned when a candidate contains it.
    struct Rule: Sendable {
        let token: String
        let assetName: String?
    }

    /// Ordered classification rules. Candidates are tested against each rule in
    /// order; the first rule whose `token` is contained in the candidate wins.
    let rules: [Rule]

    /// The production classifier. Token order and asset names mirror the agents'
    /// brand marks exactly (opencode, hermes, claude, codex), sourcing each asset
    /// name from the owning `SessionAgent` case so there is a single source of
    /// truth for the brand-mark image names.
    static let standard = SessionAgentAssetResolver(rules: [
        Rule(token: "opencode", assetName: SessionAgent.opencode.assetName),
        Rule(token: "hermes", assetName: SessionAgent.hermesAgent.assetName),
        Rule(token: "claude", assetName: SessionAgent.claude.assetName),
        Rule(token: "codex", assetName: SessionAgent.codex.assetName)
    ])

    /// Returns the brand-mark asset name for the first candidate whose lowercased
    /// text contains a known agent token, trying candidates in order. Returns
    /// `nil` when no candidate matches.
    func assetName(forNameCandidates candidates: [String?]) -> String? {
        for candidate in candidates.compactMap({ $0?.lowercased() }) {
            for rule in rules where candidate.contains(rule.token) {
                return rule.assetName
            }
        }
        return nil
    }

    /// Builds a process-id to asset-name index from already-resolved coding-agent
    /// aggregate rows, mapping every process id under an agent row to that row's
    /// `agentAssetName`. Pure attribution over the rows; uses no classifier state.
    func agentAssetNameByProcessID(from agentRows: [CmuxTaskManagerRow]) -> [Int: String] {
        var assetNameByProcessID: [Int: String] = [:]
        for row in agentRows {
            guard let assetName = row.agentAssetName else { continue }
            for processID in row.resources.processIds {
                assetNameByProcessID[processID] = assetName
            }
        }
        return assetNameByProcessID
    }

    /// Attributes an agent asset to each row that does not already carry one by
    /// matching the row's process ids against `assetNameByProcessID`. A row is
    /// tagged only when every matching process id resolves to a single asset
    /// name; window rows and rows already carrying an asset are left untouched.
    /// Pure attribution over the rows; uses no classifier state.
    func rowsWithAgentAssets(
        _ rows: [CmuxTaskManagerRow],
        assetNameByProcessID: [Int: String]
    ) -> [CmuxTaskManagerRow] {
        guard !assetNameByProcessID.isEmpty else { return rows }
        return rows.map { row in
            if row.agentAssetName != nil {
                return row
            }
            guard row.kind != .window else {
                return row
            }

            var assetNames = Set<String>()
            for processID in row.resources.processIds {
                if let assetName = assetNameByProcessID[processID] {
                    assetNames.insert(assetName)
                }
            }
            if let processID = row.processId,
               let assetName = assetNameByProcessID[processID] {
                assetNames.insert(assetName)
            }
            for processID in row.rootProcessIds {
                if let assetName = assetNameByProcessID[processID] {
                    assetNames.insert(assetName)
                }
            }

            guard assetNames.count == 1, let assetName = assetNames.first else {
                return row
            }
            return row.withAgentAssetName(assetName)
        }
    }
}
