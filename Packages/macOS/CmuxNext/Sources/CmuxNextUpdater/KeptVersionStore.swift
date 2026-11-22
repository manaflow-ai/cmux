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

    /// Keeps `bundle` as `build`, then prunes to the newest `limit`.
    public func keep(bundle: URL, build: String, limit: Int) throws {
        let files = FileManager.default
        guard limit > 0 else { return prune(limit: 0) }
        let folder = root.appending(path: build, directoryHint: .isDirectory)
        if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: bundle.lastPathComponent)
        // APFS clone of the whole tree; a plain copy where cloning fails
        // (another volume, an old file system).
        if clonefile(bundle.path, target.path, 0) != 0 {
            try files.copyItem(at: bundle, to: target)
        }
        prune(limit: limit)
    }

    /// Kept versions, newest build first.
    public func list() -> [KeptVersion] {
        let files = FileManager.default
        guard let builds = try? files.contentsOfDirectory(atPath: root.path) else { return [] }
        return builds.compactMap { build -> KeptVersion? in
            let folder = root.appending(path: build, directoryHint: .isDirectory)
            guard let app = (try? files.contentsOfDirectory(atPath: folder.path))?.first(where: { $0.hasSuffix(".app") }) else { return nil }
            let bundle = folder.appending(path: app, directoryHint: .isDirectory)
            let info = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
            let schemas = (info["CmuxStoreSchemas"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.intValue }
            return KeptVersion(build: info["CFBundleVersion"] as? String ?? build,
                               shortVersion: info["CFBundleShortVersionString"] as? String ?? build,
                               bundle: bundle, storeSchemas: schemas, teamID: teamID(bundle))
        }
        .sorted { Self.isNewer($0.build, than: $1.build) }
    }

    private func prune(limit: Int) {
        for old in list().dropFirst(limit) {
            try? FileManager.default.removeItem(at: old.bundle.deletingLastPathComponent())
        }
    }

    /// Numeric build order (CFBundleVersion is monotonic, R78).
    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }
}
