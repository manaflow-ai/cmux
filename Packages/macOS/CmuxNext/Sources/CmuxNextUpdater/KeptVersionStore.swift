public import Foundation
import Darwin

/// Previous app versions kept for rollback (`updates.keepPreviousVersions`):
/// `<root>/<build>/<App>.app`, cloned (APFS clonefile, no extra disk until
/// blocks change) right before Sparkle installs over the running bundle.
///
/// Each kept build has a record beside it (`<root>/<build>/kept.json`, ``KeptRecord``): when it was
/// kept, its build date, the signing team checked when it was kept, and the store schemas it reads.
/// A rollback reads the record instead of checking the whole bundle's signature again (a deep check
/// of a CEF bundle took seconds, and a rollback made three: the list, the running app, the prune).
nonisolated public struct KeptVersionStore: Sendable {
    public let root: URL
    /// The signing team of a bundle with a full check of every file (SecStaticCode in the app;
    /// injected in tests). Only a bundle kept without a record pays it.
    public let teamID: @Sendable (URL) -> String?
    /// The signing team of a bundle with the quick check a rollback makes at the click: the main
    /// executable and its Info.plist, not every resource (the full check ran when it was kept).
    public let quickTeamID: @Sendable (URL) -> String?
    /// The clock a keep records (tests set one).
    public var now: @Sendable () -> Date = { Date() }

    public init(root: URL, teamID: @escaping @Sendable (URL) -> String?, quickTeamID: (@Sendable (URL) -> String?)? = nil) {
        self.root = root
        self.teamID = teamID
        self.quickTeamID = quickTeamID ?? teamID
    }

    /// The name of the record beside a kept bundle.
    static let recordName = "kept.json"

    /// Keeps `bundle` as `build`, then prunes to the `limit` kept most recently (nil: no prune, for
    /// a build downloaded to switch to, which may be older than every kept one). `record` is what is
    /// known about it (the team its signature was checked for, the schemas it reads, its date); the
    /// keep adds when it was kept.
    public func keep(bundle: URL, build: String, limit: Int?, record: KeptRecord? = nil) throws {
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
        var written = record ?? KeptRecord(build: build)
        written.build = build
        written.keptAt = now()
        written.signature = KeptRecord.Fingerprint(bundle: target)
        // Best effort: without a record the next list checks the signature in full, as before.
        try? written.write(to: folder.appending(path: Self.recordName))
        if let limit { prune(limit: limit, keeping: build) }
    }

    /// Kept versions, newest build first. Without `teams` no signature is read (a prune, the card's
    /// label): ``KeptVersion/teamID`` is the record's, unchecked.
    public func list(teams: Bool = true) -> [KeptVersion] {
        let files = FileManager.default
        guard let builds = try? files.contentsOfDirectory(atPath: root.path) else { return [] }
        return builds.compactMap { build -> KeptVersion? in
            let folder = root.appending(path: build, directoryHint: .isDirectory)
            guard let app = (try? files.contentsOfDirectory(atPath: folder.path))?.first(where: { $0.hasSuffix(".app") && !$0.hasPrefix(".") })
            else { return nil }
            let bundle = folder.appending(path: app, directoryHint: .isDirectory)
            let info = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
            let record = KeptRecord.read(from: folder.appending(path: Self.recordName))
            let plistSchemas = (info["CmuxStoreSchemas"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.intValue }
            // The record's team stands while the bundle's signature files are the ones it was kept
            // with, confirmed by the quick check; anything else checks every file, as before.
            let team: String? = if !teams {
                record?.teamID
            } else if let record, let recorded = record.teamID, record.signature == KeptRecord.Fingerprint(bundle: bundle) {
                quickTeamID(bundle) == recorded ? recorded : nil
            } else {
                teamID(bundle)
            }
            return KeptVersion(build: info["CFBundleVersion"] as? String ?? build,
                               shortVersion: info["CFBundleShortVersionString"] as? String ?? build,
                               bundle: bundle, storeSchemas: plistSchemas ?? record?.storeSchemas, teamID: team,
                               keptAt: record?.keptAt, date: record?.date)
        }
        .sorted { Self.isNewer($0.build, than: $1.build) }
    }

    /// Keeps the `limit` builds kept most recently (the one just kept always among them), so the
    /// build this Mac came from stays even when a newer one was kept before it (a rollback keeps
    /// the build it left). Builds with no record count as kept long ago, newest build first.
    private func prune(limit: Int, keeping build: String? = nil) {
        let order = list(teams: false).sorted { a, b in
            if (a.build == build) != (b.build == build) { return a.build == build }
            let (x, y) = (a.keptAt ?? .distantPast, b.keptAt ?? .distantPast)
            return x != y ? x > y : Self.isNewer(a.build, than: b.build)
        }
        for old in order.dropFirst(limit) {
            try? FileManager.default.removeItem(at: old.bundle.deletingLastPathComponent())
        }
    }

    /// Removes what a keep or swap cut short left behind: a build folder with no app in it (a
    /// clone stopped half way, `.partial` only, or a swap that took the app out). Run at launch,
    /// off the main thread.
    public func sweep() -> [String] {
        let files = FileManager.default
        guard let builds = try? files.contentsOfDirectory(atPath: root.path) else { return [] }
        var removed: [String] = []
        for build in builds where !build.hasPrefix(".") {
            let folder = root.appending(path: build, directoryHint: .isDirectory)
            let entries = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
            if !entries.contains(where: { $0.hasSuffix(".app") && !$0.hasPrefix(".") }) {
                try? files.removeItem(at: folder)
                removed.append(build)
            }
        }
        return removed
    }

    /// Numeric build order (CFBundleVersion is monotonic, R78).
    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }
}

/// What is known about a kept build (`kept.json` beside it).
nonisolated public struct KeptRecord: Codable, Equatable, Sendable {
    /// The size and change time of the bundle's signature files when it was kept: a record's team
    /// stands only while they are the same.
    public struct Fingerprint: Codable, Equatable, Sendable {
        public var resources: [Int64]
        public var executable: [Int64]

        init?(bundle: URL) {
            let info = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")) as? [String: Any]
            guard let name = info?["CFBundleExecutable"] as? String,
                  let resources = Self.stamp(bundle.appending(path: "Contents/_CodeSignature/CodeResources")),
                  let executable = Self.stamp(bundle.appending(path: "Contents/MacOS/\(name)")) else { return nil }
            self.resources = resources
            self.executable = executable
        }

        private static func stamp(_ file: URL) -> [Int64]? {
            var info = stat()
            guard stat(file.path, &info) == 0 else { return nil }
            return [Int64(info.st_size), Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec), Int64(info.st_ino)]
        }
    }

    public var build: String
    /// When it was kept (the update that left it, or the download that kept it).
    public var keptAt: Date?
    /// When the build was made, `YYYY-MM-DD` (the feed's notes); nil when not known.
    public var date: String?
    /// The team its signature was checked for, in full, when it was kept.
    public var teamID: String?
    /// The store schemas it reads (its Info.plist, else its CLI), read when it was kept.
    public var storeSchemas: [String: Int]?
    var signature: Fingerprint?

    public init(build: String, date: String? = nil, teamID: String? = nil, storeSchemas: [String: Int]? = nil) {
        self.build = build
        self.date = date
        self.teamID = teamID
        self.storeSchemas = storeSchemas
    }

    static func read(from file: URL) -> KeptRecord? {
        guard let data = try? Data(blockingContentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KeptRecord.self, from: data)
    }

    func write(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}
