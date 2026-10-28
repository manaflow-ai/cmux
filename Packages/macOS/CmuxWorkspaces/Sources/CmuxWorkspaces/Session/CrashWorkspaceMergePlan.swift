/// Selects whole workspace copies while preserving unmatched or divergent state.
///
/// The app applies this plan to its snapshots. The policy owns only immutable
/// matching evidence, so it can be tested without launching an app host.
public struct CrashWorkspaceMergePlan: Sendable {
    /// A workspace's position in one of the two original generations.
    public enum Source: Equatable, Sendable {
        /// Keep a workspace from the preferred window, at its original index.
        case preferred(Int)
        /// Keep a workspace from the supplemental window, at its original index.
        case supplemental(Int)
    }

    /// The chosen workspace copies, in restore order.
    public let selections: [Source]
    /// Preferred-to-supplemental matches, used to reconcile persisted group anchors.
    public let matches: [Int: Int]

    /// Matches each original workspace at most once and keeps every unmatched copy.
    /// - Parameters:
    ///   - preferred: The window whose ordering and selection will be retained.
    ///   - supplemental: The other crash generation, whose unmatched workspaces are appended.
    public nonisolated init(preferred: [CrashWorkspaceSignature], supplemental: [CrashWorkspaceSignature]) {
        let index = CrashWorkspaceMatchIndex(preferred)
        var selections = preferred.indices.map(Source.preferred)
        var matches: [Int: Int] = [:]
        var consumed: Set<Int> = []
        let order = supplemental.indices.sorted {
            let left = index.candidateMatches(supplemental[$0]).count
            let right = index.candidateMatches(supplemental[$1]).count
            return left == right ? $0 < $1 : left < right
        }
        var matchedSupplemental: Set<Int> = []
        for supplementalIndex in order {
            let workspace = supplemental[supplementalIndex]
            if let preferredIndex = index.match(workspace, excluding: consumed) {
                consumed.insert(preferredIndex)
                matchedSupplemental.insert(supplementalIndex)
                matches[preferredIndex] = supplementalIndex
                if workspace.isPreferred(over: preferred[preferredIndex]) {
                    selections[preferredIndex] = .supplemental(supplementalIndex)
                }
            }
        }
        selections.append(contentsOf: supplemental.indices.compactMap {
            matchedSupplemental.contains($0) ? nil : .supplemental($0)
        })
        self.selections = selections
        self.matches = matches
    }
}
