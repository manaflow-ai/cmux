nonisolated struct CmuxConfigActionCatalogDirectoryIndexMutation: Equatable, Sendable {
    var changedSources: Set<CmuxConfigActionCatalogDirectorySource> = []
    var newlyActiveKeys: Set<String> = []
    var inactiveKeys: Set<String> = []

    mutating func formUnion(_ other: Self) {
        changedSources.formUnion(other.changedSources)
        newlyActiveKeys.formUnion(other.newlyActiveKeys)
        inactiveKeys.formUnion(other.inactiveKeys)
    }
}
