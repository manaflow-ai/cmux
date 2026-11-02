public import Foundation
import Darwin

/// Previous app versions kept for rollback (`updates.keepPreviousVersions`):
/// `<root>/<build>/<App>.app`, cloned (APFS clonefile, no extra disk until
/// blocks change) right before Sparkle installs over the running bundle.
nonisolated public struct KeptVersionStore: Sendable {
    public let root: URL
    /// The signing team of a bundle (SecStaticCode in the app; injected in tests).
    public let teamID: @Sendable (URL) -> String?

    public init(root: URL, teamID: @escaping @Sendable (URL) -> String?) {
        self.root = root
        self.teamID = teamID
    }

    /// Keeps `bundle` as `build`, then prunes to the newest `limit` (nil: no prune, for a build
    /// downloaded to switch to, which may be older than every kept one).
    public func keep(bundle: URL, build: String, limit: Int?) throws {
        let files = FileManager.default
        if let limit, limit <= 0 { return prune(limit: 0) }
        let folder = root.appending(path: build, directoryHint: .isDirectory)
        if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: bundle.lastPathComponent)
        // Cloned under a name `list()` never reads, then renamed: a keep cut
        // short (the app exits for the update while it runs) never leaves a
        // partial bundle that looks like a rollback target.
        let partial = folder.appending(path: "." + bundle.lastPathComponent + ".partial")
        // APFS clone of the whole tree; a plain copy where cloning fails
        // (another volume, an old file system).
        if clonefile(bundle.path, partial.path, 0) != 0 {
            try files.copyItem(at: bundle, to: partial)
        }
        try files.moveItem(at: partial, to: target)
        if let limit { prune(limit: limit) }
    }

    /// Kept versions, newest build first.
    public func list() -> [KeptVersion] {
        let files = FileManager.default
        guard let builds = try? files.contentsOfDirectory(atPath: root.path) else { return [] }
        let kept = builds.compactMap { build -> KeptVersion? in
            let folder = root.appending(path: build, directoryHint: .isDirectory)
            guard let app = (try? files.contentsOfDirectory(atPath: folder.path))?.first(where: { $0.hasSuffix(".app") }) else { return nil }
            let bundle = folder.appending(path: app, directoryHint: .isDirectory)
            let info = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
            let schemas = (info["CmuxStoreSchemas"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.intValue }
            return KeptVersion(build: info["CFBundleVersion"] as? String ?? build,
                               shortVersion: info["CFBundleShortVersionString"] as? String ?? build,
                               bundle: bundle, storeSchemas: schemas, teamID: teamID(bundle))
        }
        return Self.newestFirst(kept)
    }

    private func prune(limit: Int) {
        for old in list().dropFirst(limit) {
            try? FileManager.default.removeItem(at: old.bundle.deletingLastPathComponent())
        }
    }

    /// `kept`, newest build first: numeric build order (CFBundleVersion is monotonic, R78), from
    /// the update rules (cmux-updater-core `updater_builds_newest_first`; equal builds keep their order).
    static func newestFirst(_ kept: [KeptVersion]) -> [KeptVersion] {
        let answer: KeptOrderAnswer? = UpdaterRules().call("updater_builds_newest_first",
                                                           json: KeptOrderRequest(builds: kept.map(\.build)))
        guard let order = answer?.order, order.count == kept.count, order.allSatisfy({ kept.indices.contains($0) }) else { return kept }
        return order.map { kept[$0] }
    }
}

nonisolated private struct KeptOrderRequest: Encodable {
    var builds: [String]
}

nonisolated private struct KeptOrderAnswer: Decodable {
    var order: [Int]
}
