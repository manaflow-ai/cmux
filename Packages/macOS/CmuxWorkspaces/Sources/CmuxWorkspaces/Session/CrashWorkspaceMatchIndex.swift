import Foundation

/// Indexes one immutable generation; each workspace can be matched only once.
struct CrashWorkspaceMatchIndex {
    private let workspaces: [CrashWorkspaceSignature]
    private var stableIDs: [UUID: [Int]] = [:]
    private var workspaceIDs: [UUID: [Int]] = [:]
    private var checkpoints: [String: Set<Int>] = [:]
    private var titles: [CrashWorkspaceTitleKey: [Int]] = [:]

    nonisolated init(_ workspaces: [CrashWorkspaceSignature]) {
        self.workspaces = workspaces
        for (index, workspace) in workspaces.enumerated() {
            if let id = workspace.stableID { stableIDs[id, default: []].append(index) }
            if let id = workspace.workspaceID { workspaceIDs[id, default: []].append(index) }
            for checkpoint in workspace.checkpointIDs { checkpoints[checkpoint, default: []].insert(index) }
            if let key = titleKey(workspace) { titles[key, default: []].append(index) }
        }
    }

    nonisolated func match(_ workspace: CrashWorkspaceSignature, excluding consumed: Set<Int>) -> Int? {
        uniqueCompatibleMatch(candidateMatches(workspace), workspace: workspace, excluding: consumed)
    }

    /// Returns all possible matches before consumption, so the caller can
    /// solve ambiguous candidates in the most constrained-first order.
    nonisolated func candidateMatches(_ workspace: CrashWorkspaceSignature) -> [Int] {
        if let id = workspace.stableID, let matches = stableIDs[id] { return matches }
        if let id = workspace.workspaceID, let matches = workspaceIDs[id] { return matches }
        var candidates: Set<Int> = []
        for checkpoint in workspace.checkpointIDs {
            candidates.formUnion(checkpoints[checkpoint] ?? [])
        }
        if !candidates.isEmpty { return Array(candidates) }
        if let key = titleKey(workspace), let matches = titles[key], matches.count == 1 {
            return matches
        }
        return []
    }

    private nonisolated func uniqueCompatibleMatch(
        _ candidates: [Int], workspace: CrashWorkspaceSignature, excluding consumed: Set<Int>
    ) -> Int? {
        var match: Int?
        for index in candidates where !consumed.contains(index) && workspace.canMerge(with: workspaces[index]) {
            guard match == nil else { return nil }
            match = index
        }
        return match
    }

    private nonisolated func titleKey(_ workspace: CrashWorkspaceSignature) -> CrashWorkspaceTitleKey? {
        guard let title = workspace.title, !title.isEmpty, !workspace.directory.isEmpty else { return nil }
        return CrashWorkspaceTitleKey(title: title, description: workspace.description, directory: workspace.directory)
    }
}
