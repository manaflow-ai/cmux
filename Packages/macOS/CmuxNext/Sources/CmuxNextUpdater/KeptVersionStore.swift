public import Foundation
import Darwin

/// Previous app versions kept for rollback (`updates.keepPreviousVersions`):
/// `<root>/<build>/<App>.app.kept`, cloned (APFS clonefile, no extra disk until
/// blocks change) right before Sparkle installs over the running bundle.
///
/// Not named `.app`: LaunchServices registered every kept `.app` under the
/// app's bundle id (2026-11-08: dozens of kept DEV bundles in
/// `lsregister -dump`), so `open -b` and a URL could start a kept build.
/// A folder without the extension is no bundle to LaunchServices; codesign
/// and the rollback read it the same. Kept `.app` folders from before are
/// renamed at the next keep, and still listed until then.
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
        Self.renameLegacyKeeps(in: root, files: files)
        let target = folder.appending(path: bundle.lastPathComponent + Self.keptSuffix)
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
        return builds.compactMap { build -> KeptVersion? in
            let folder = root.appending(path: build, directoryHint: .isDirectory)
            guard let app = (try? files.contentsOfDirectory(atPath: folder.path))?.first(where: Self.isKeptBundle) else { return nil }
            let bundle = folder.appending(path: app, directoryHint: .isDirectory)
            let info = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
            let schemas = (info["CmuxStoreSchemas"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.intValue }
            return KeptVersion(build: info["CFBundleVersion"] as? String ?? build,
                               shortVersion: info["CFBundleShortVersionString"] as? String ?? build,
                               bundle: bundle, storeSchemas: schemas, teamID: teamID(bundle))
        }
        .sorted { Self.isNewer($0.build, than: $1.build) }
    }

    /// What a kept bundle's name ends with (after `.app`).
    static let keptSuffix = ".kept"

    /// A kept bundle's name: `<App>.app.kept`, or `<App>.app` from before; never a hidden partial.
    static func isKeptBundle(_ name: String) -> Bool {
        !name.hasPrefix(".") && (name.hasSuffix(".app" + keptSuffix) || name.hasSuffix(".app"))
    }

    /// Renames kept `<App>.app` folders from before to `<App>.app.kept`, so LaunchServices no longer offers them.
    static func renameLegacyKeeps(in root: URL, files: FileManager) {
        for build in (try? files.contentsOfDirectory(atPath: root.path)) ?? [] {
            let folder = root.appending(path: build, directoryHint: .isDirectory)
            for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") && name.hasSuffix(".app") {
                try? files.moveItem(at: folder.appending(path: name), to: folder.appending(path: name + keptSuffix))
            }
        }
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
