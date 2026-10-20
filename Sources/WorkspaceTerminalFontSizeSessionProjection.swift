import Foundation

extension WorkspaceTerminalFontSizeSnapshotProjection {
    struct SessionProjection {
        let overrideBasePoints: Float32?
        let representedRequestTokens: Set<UUID>

        var persistedRepresentedRequestTokens: [UUID]? {
            guard !representedRequestTokens.isEmpty else { return nil }
            return representedRequestTokens.sorted {
                $0.uuidString < $1.uuidString
            }
        }
    }
}
