/// Captures presentation state only when it changed, without rebuilding every row on an unchanged pass.
@MainActor package struct SidebarSnapshotCapture {
    private var savedKey: Key?

    private struct Key: Equatable {
        var revision: UInt64
        var profiles: [SidebarProfile]
        var activeProfile: ProfileKey?
        var folds: Set<SidebarDoneFoldID>
    }

    package init() {}

    package mutating func take(_ model: SidebarModel) -> SidebarSnapshot? {
        let key = Key(revision: model.contentRevision, profiles: model.profiles,
                      activeProfile: model.activeProfileID, folds: model.openDoneFolds)
        guard savedKey != key else { return nil }
        savedKey = key
        var snapshot = SidebarSnapshot(sections: model.sections, profiles: model.profiles, activeProfileID: model.activeProfileID)
        snapshot.openDoneFolds = model.openDoneFolds
        return snapshot
    }
}
