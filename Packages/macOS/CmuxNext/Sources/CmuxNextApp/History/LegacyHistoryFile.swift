import Foundation

/// One app-local history file retained across the daemon handoff.
struct LegacyHistoryFile: Equatable, Sendable {
    let url: URL

    init?(url: URL, supportDirectory _: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        self.url = url
    }

    func removeIfUnchanged() {
        try? FileManager.default.removeItem(at: url)
    }
}
