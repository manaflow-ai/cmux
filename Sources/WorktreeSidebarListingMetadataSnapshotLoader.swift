import Foundation

/// Reads only direct registration names and small files that affect worktree listing.
actor WorktreeSidebarListingMetadataSnapshotLoader {
    private static let maximumMetadataBytes = 4_096
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func load(
        plan: WorktreeSidebarListingWatchPlan
    ) -> WorktreeSidebarListingMetadataSnapshot {
        let membershipNames = plan.membershipDirectory.flatMap {
            try? fileManager.contentsOfDirectory(atPath: $0).sorted()
        }
        var metadataContents: [String: Data] = [:]
        for path in plan.metadataPaths {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                continue
            }
            metadataContents[path] = (try? handle.read(upToCount: Self.maximumMetadataBytes)) ?? Data()
            try? handle.close()
        }
        return WorktreeSidebarListingMetadataSnapshot(
            membershipNames: membershipNames,
            metadataContents: metadataContents
        )
    }
}
