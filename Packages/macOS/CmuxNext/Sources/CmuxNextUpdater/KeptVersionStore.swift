import CmuxNextCompat
import CryptoKit
public import Foundation
import Darwin
import os

/// Previous app versions kept for rollback (`updates.keepPreviousVersions`):
/// `<root>/<build>/<App>.app`, cloned (APFS clonefile, no extra disk until
/// blocks change) right before Sparkle installs over the running bundle.
nonisolated public struct KeptVersionStore: Sendable {
    public let root: URL
    /// The signing team of a bundle (SecStaticCode in the app; injected in tests). A full check of
    /// every nested binary takes seconds per bundle on a busy Mac, so ``list()`` never runs it:
    /// only ``verified(_:)`` does, for the one build a rollback goes to.
    public let teamID: @Sendable (URL) -> String?

    /// Teams already read (``verified(_:reusing:)``); the updater owns one for the app's life.
    let teams: SigningTeamCache

    public init(root: URL, teamID: @escaping @Sendable (URL) -> String?, teams: SigningTeamCache = SigningTeamCache()) {
        self.root = root
        self.teamID = teamID
        self.teams = teams
    }

    /// Keeps `bundle` as `build`, then prunes to the newest `limit` (nil: no prune, for a build
    /// downloaded to switch to, which may be older than every kept one).
    public func keep(bundle: URL, build: String, limit: Int?) throws {
        let files = FileManager.default
        if let limit, limit <= 0 { return prune(limit: 0) }
        let folder = root.appending(path: build, directoryHint: .isDirectory)
        // The schemas this build reads do not change with a new copy of it: a re-keep keeps them.
        let schemas = try? Data(blockingContentsOf: Self.schemasFile(in: folder))
        if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        if let schemas { try? schemas.blockingWrite(to: Self.schemasFile(in: folder), options: .atomic) }
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

    /// Kept versions, newest build first: a directory listing and each bundle's Info.plist, no
    /// signature check (``KeptVersion/teamID`` is nil until ``verified(_:)``).
    public func list() -> [KeptVersion] {
        let files = FileManager.default
        guard let builds = try? files.contentsOfDirectory(atPath: root.path) else { return [] }
        return builds.compactMap { build -> KeptVersion? in
            let folder = root.appending(path: build, directoryHint: .isDirectory)
            guard let app = (try? files.contentsOfDirectory(atPath: folder.path))?.first(where: { $0.hasSuffix(".app") }) else { return nil }
            let bundle = folder.appending(path: app, directoryHint: .isDirectory)
            let info = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
            let schemas = (info["CmuxStoreSchemas"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.intValue }
                ?? Self.recordedSchemas(in: folder, bundle: bundle)
            return KeptVersion(build: info["CFBundleVersion"] as? String ?? build,
                               shortVersion: info["CFBundleShortVersionString"] as? String ?? build,
                               bundle: bundle, storeSchemas: schemas, teamID: nil)
        }
        .sorted { Self.isNewer($0.build, than: $1.build) }
    }

    /// `version` with its signing team read: the one full signature check a rollback makes, of
    /// its target only. `reusing` takes an earlier answer while the bundle on disk stays the same
    /// (the Channels card's "would it run" read); the rollback itself checks afresh, so a bundle
    /// changed since the card read it is refused.
    public func verified(_ version: KeptVersion, reusing: Bool = false) -> KeptVersion {
        var version = version
        version.teamID = teams.team(of: version.bundle, reusing: reusing, read: teamID)
        return version
    }

    /// Records the schemas `build` reads (its own CLI's answer), so the next rollback to it reads
    /// a file instead of starting that CLI cold (a first run of a new binary waits on the system's
    /// scan of it, past the probe's timeout on a busy Mac). The record names the bundle it was
    /// read from by the digest of its signed seal (`Contents/_CodeSignature/CodeResources`, which
    /// the signature covers and the rollback checks afresh): a record for any other bundle, a
    /// stale one or one written for another copy, is never read, and the target's CLI runs again.
    public func recordSchemas(_ schemas: [String: Int], for build: String) {
        let folder = root.appending(path: build, directoryHint: .isDirectory)
        guard let app = (try? FileManager.checked.contentsOfDirectory(atPath: folder.path))?.first(where: { $0.hasSuffix(".app") }),
              let seal = Self.seal(of: folder.appending(path: app, directoryHint: .isDirectory)),
              let data = try? JSONSerialization.data(withJSONObject: ["seal": seal, "schemas": schemas], options: [.sortedKeys])
        else { return }
        try? data.blockingWrite(to: Self.schemasFile(in: folder), options: .atomic)
    }

    static func schemasFile(in folder: URL) -> URL { folder.appending(path: "store-schemas.json") }

    /// The record's schemas when it was read from `bundle` as it is on disk now, else nil.
    static func recordedSchemas(in folder: URL, bundle: URL) -> [String: Int]? {
        guard let data = try? Data(blockingContentsOf: schemasFile(in: folder)),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let recorded = record["seal"] as? String, recorded == seal(of: bundle),
              let schemas = record["schemas"], let inner = try? JSONSerialization.data(withJSONObject: schemas)
        else { return nil }
        return StoreSchemaProbe.parse(inner)
    }

    /// The SHA-256 of `bundle`'s signed seal, hex; nil for a bundle without one.
    static func seal(of bundle: URL) -> String? {
        guard let data = try? Data(blockingContentsOf: bundle.appending(path: "Contents/_CodeSignature/CodeResources")) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

/// Signing teams already read, by bundle path and the identity of its code directory's seal
/// (`Contents/_CodeSignature/CodeResources`: a new copy at the same path is a new file), so each
/// open of the Channels card does not check the same kept build again, and the running app's own
/// team is read once.
nonisolated public final class SigningTeamCache: Sendable {
    public init() {}

    private let teams = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Without `reusing` the bundle is checked again (and the answer remembered). A failed check
    /// is not remembered: it is read again next time.
    func team(of bundle: URL, reusing: Bool = true, read: (URL) -> String?) -> String? {
        guard let key = Self.key(of: bundle) else { return read(bundle) }
        if reusing, let known = teams.withLock({ $0[key] }) { return known }
        guard let team = read(bundle) else {
            teams.withLock { $0[key] = nil }
            return nil
        }
        teams.withLock { $0[key] = team }
        return team
    }

    static func key(of bundle: URL) -> String? {
        let seal = bundle.appending(path: "Contents/_CodeSignature/CodeResources").path
        guard let attributes = try? FileManager.checked.attributesOfItem(atPath: seal),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(bundle.standardizedFileURL.path)\u{0}\(inode)\u{0}\(modified.timeIntervalSince1970)"
    }
}
