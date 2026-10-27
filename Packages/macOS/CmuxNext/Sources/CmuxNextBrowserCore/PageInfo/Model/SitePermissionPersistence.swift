import CmuxNextCompat
public import Foundation

/// Every stored decision of one profile: origin -> permission -> setting.
public nonisolated struct SitePermissionSnapshot: Codable, Hashable, Sendable {
    public var version: Int
    public var origins: [String: [SitePermissionKind: SitePermissionSetting]]

    public init(origins: [String: [SitePermissionKind: SitePermissionSetting]] = [:]) {
        version = 1
        self.origins = origins
    }
}

/// Where a profile's decisions live. Implementations do their IO off the
/// main actor (architecture.md 5a).
public protocol SitePermissionPersistence: Sendable {
    func load() async -> SitePermissionSnapshot
    func save(_ snapshot: SitePermissionSnapshot) async
}

/// One JSON file per profile, written atomically. Saves are serialized by
/// the actor, so the last snapshot handed in is the one on disk.
public actor FileSitePermissionPersistence: SitePermissionPersistence {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() async -> SitePermissionSnapshot {
        Self.read(fileURL)
    }

    public func save(_ snapshot: SitePermissionSnapshot) async {
        Self.write(snapshot, to: fileURL)
    }

    /// The decisions in `fileURL`, empty when it is missing or unreadable. Blocking: a lane or this actor only.
    public nonisolated static func read(_ fileURL: URL) -> SitePermissionSnapshot {
        // concurrency-allow: called on this actor's executor or a files lane, never the main actor.
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().blockingDecode(SitePermissionSnapshot.self, from: data) else {
            return SitePermissionSnapshot()
        }
        return snapshot
    }

    /// Writes `snapshot` to `fileURL` atomically, making its folder. Blocking: a lane or this actor only.
    public nonisolated static func write(_ snapshot: SitePermissionSnapshot, to fileURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
