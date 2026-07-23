import Foundation

struct CmuxConfigActionCatalogDirectoryIndex {
    private var keyBySource: [CmuxConfigActionCatalogDirectorySource: String]
    private var sourcesByWorkspaceID: [UUID: Set<CmuxConfigActionCatalogDirectorySource>] = [:]
    private(set) var referenceCounts: [String: Int]

    init(globalKey: String) {
        keyBySource = [.global: globalKey]
        referenceCounts = [globalKey: 1]
    }

    var activeKeys: Set<String> {
        Set(referenceCounts.keys)
    }

    var contributionCount: Int {
        keyBySource.count
    }

    func key(for source: CmuxConfigActionCatalogDirectorySource) -> String? {
        keyBySource[source]
    }

    func referenceCount(for key: String) -> Int {
        referenceCounts[key, default: 0]
    }

    @discardableResult
    mutating func replaceContribution(
        source: CmuxConfigActionCatalogDirectorySource,
        key: String?
    ) -> CmuxConfigActionCatalogDirectoryIndexMutation {
        guard source != .global else { return .init() }
        guard let key else { return removeContribution(source: source) }
        let previousKey = keyBySource[source]
        guard previousKey != key else { return .init() }

        var mutation = CmuxConfigActionCatalogDirectoryIndexMutation(
            changedSources: [source]
        )
        if let previousKey {
            decrementReferenceCount(for: previousKey, mutation: &mutation)
        }
        if referenceCounts[key, default: 0] == 0 {
            mutation.newlyActiveKeys.insert(key)
        }
        referenceCounts[key, default: 0] += 1
        keyBySource[source] = key
        if let workspaceID = source.workspaceID {
            sourcesByWorkspaceID[workspaceID, default: []].insert(source)
        }
        return mutation
    }

    @discardableResult
    mutating func removeContribution(
        source: CmuxConfigActionCatalogDirectorySource
    ) -> CmuxConfigActionCatalogDirectoryIndexMutation {
        guard source != .global,
              let previousKey = keyBySource.removeValue(forKey: source) else {
            return .init()
        }
        var mutation = CmuxConfigActionCatalogDirectoryIndexMutation(
            changedSources: [source]
        )
        decrementReferenceCount(for: previousKey, mutation: &mutation)
        if let workspaceID = source.workspaceID {
            sourcesByWorkspaceID[workspaceID]?.remove(source)
            if sourcesByWorkspaceID[workspaceID]?.isEmpty == true {
                sourcesByWorkspaceID.removeValue(forKey: workspaceID)
            }
        }
        return mutation
    }

    @discardableResult
    mutating func replaceWorkspace(
        workspaceID: UUID,
        workspaceKey: String?,
        panelKeys: [UUID: String]
    ) -> CmuxConfigActionCatalogDirectoryIndexMutation {
        let previouslyActiveKeys = activeKeys
        var desired: [CmuxConfigActionCatalogDirectorySource: String] = [:]
        if let workspaceKey {
            desired[.workspace(workspaceID)] = workspaceKey
        }
        for (panelID, key) in panelKeys {
            desired[.panel(workspaceID: workspaceID, panelID: panelID)] = key
        }

        var mutation = CmuxConfigActionCatalogDirectoryIndexMutation()
        let previousSources = sourcesByWorkspaceID[workspaceID] ?? []
        for source in previousSources.subtracting(desired.keys) {
            mutation.formUnion(removeContribution(source: source))
        }
        for (source, key) in desired {
            mutation.formUnion(replaceContribution(source: source, key: key))
        }
        mutation.newlyActiveKeys = activeKeys.subtracting(previouslyActiveKeys)
        mutation.inactiveKeys = previouslyActiveKeys.subtracting(activeKeys)
        return mutation
    }

    @discardableResult
    mutating func removeWorkspace(
        workspaceID: UUID
    ) -> CmuxConfigActionCatalogDirectoryIndexMutation {
        var mutation = CmuxConfigActionCatalogDirectoryIndexMutation()
        for source in sourcesByWorkspaceID[workspaceID] ?? [] {
            mutation.formUnion(removeContribution(source: source))
        }
        return mutation
    }

    private mutating func decrementReferenceCount(
        for key: String,
        mutation: inout CmuxConfigActionCatalogDirectoryIndexMutation
    ) {
        let nextCount = max(0, referenceCounts[key, default: 0] - 1)
        if nextCount == 0 {
            referenceCounts.removeValue(forKey: key)
            mutation.inactiveKeys.insert(key)
        } else {
            referenceCounts[key] = nextCount
        }
    }
}
