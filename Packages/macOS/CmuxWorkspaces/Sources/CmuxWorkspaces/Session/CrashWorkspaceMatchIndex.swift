import Foundation

/// Indexes one immutable generation; each workspace can be matched only once.
struct CrashWorkspaceMatchIndex {
    private struct TitleKey: Hashable {
        let title: String
        let description: String?
        let directory: String
    }

    private let workspaces: [CrashWorkspaceSignature]
    private var stableIDs: [UUID: [Int]] = [:]
    private var workspaceIDs: [UUID: [Int]] = [:]
    private var checkpoints: [String: Set<Int>] = [:]
    private var titles: [TitleKey: [Int]] = [:]

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
        if let id = workspace.stableID, let matches = stableIDs[id] {
            return uniqueCompatibleMatch(matches, workspace: workspace, excluding: consumed)
        }
        if let id = workspace.workspaceID, let matches = workspaceIDs[id] {
            return uniqueCompatibleMatch(matches, workspace: workspace, excluding: consumed)
        }
        var candidates: Set<Int> = []
        for checkpoint in workspace.checkpointIDs {
            candidates.formUnion(checkpoints[checkpoint] ?? [])
        }
        if let match = uniqueCompatibleMatch(Array(candidates), workspace: workspace, excluding: consumed) {
            return match
        }
        if let key = titleKey(workspace), let matches = titles[key], matches.count == 1 {
            return uniqueCompatibleMatch(matches, workspace: workspace, excluding: consumed)
        }
        return nil
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

    private nonisolated func titleKey(_ workspace: CrashWorkspaceSignature) -> TitleKey? {
        guard let title = workspace.title, !title.isEmpty, !workspace.directory.isEmpty else { return nil }
        return TitleKey(title: title, description: workspace.description, directory: workspace.directory)
    }
}
