import Foundation

/// Which events the person has read, kept across relaunches for every event, including
/// open asks (the archive keeps only finished turns, and the Mac re-reports asks unread).
public struct FeedReadMarks: Sendable {
    public let url: URL
    /// The most marks kept.
    static let limit = 500

    public init(url: URL) {
        self.url = url
    }

    public static var standard: FeedReadMarks {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FeedReadMarks(url: base.appending(path: "Feed", directoryHint: .isDirectory).appending(path: "read.json"))
    }

    /// The marks of one account on this phone. The first load adopts the
    /// shared `read.json` of builds before per-account marks (it belonged to
    /// the account signed in then).
    public static func forAccount(_ accountID: String) -> FeedReadMarks {
        let legacy = standard.url
        let safe = accountID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        let marks = FeedReadMarks(url: legacy.deletingLastPathComponent().appending(path: "read-\(safe).json"))
        marks.adoptLegacy(legacy)
        return marks
    }

    func adoptLegacy(_ legacy: URL) {
        let files = FileManager.default
        guard !files.fileExists(atPath: url.path), files.fileExists(atPath: legacy.path) else { return }
        try? files.moveItem(at: legacy, to: url)
    }

    /// Account deletion: the account's marks go.
    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    public func load() -> [String] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    public func save(_ ids: [String]) {
        guard let data = try? JSONEncoder().encode(Array(ids.suffix(Self.limit))) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}
