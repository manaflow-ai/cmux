import Foundation

/// Persists bounded screenshot crops away from the main actor.
actor BrowserDesignModeScreenshotStore {
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    func save(_ pngData: Data, surfaceID: UUID) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let filename = "surface-\(surfaceID.uuidString.prefix(8))-\(timestamp)-\(UUID().uuidString.prefix(8)).png"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try pngData.write(to: url, options: .atomic)
        pruneKeepingNewest(limit: 100)
        return url
    }

    private func pruneKeepingNewest(limit: Int) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), urls.count > limit else { return }
        let ordered = urls.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for staleURL in ordered.dropFirst(limit) {
            try? fileManager.removeItem(at: staleURL)
        }
    }
}
