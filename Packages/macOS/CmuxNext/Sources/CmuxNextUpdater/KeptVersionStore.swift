import CmuxNextCompat
public import CryptoKit
public import Foundation
import Darwin

/// Previous app versions kept for rollback (`updates.keepPreviousVersions`):
/// `<root>/<build>/<App>.app`, cloned (APFS clonefile, no extra disk until
/// blocks change) right before Sparkle installs over the running bundle.
///
/// Each kept build has a record beside it (`<root>/<build>/kept.json`, ``KeptRecord``): when it was
/// kept, its build date, the store schemas it reads, and the signing team a full check of every file
/// found, sealed (``KeptSeal``). A rollback trusts that team while the seal matches instead of checking
/// the whole bundle again (a deep check of a CEF bundle took seconds, and a rollback made three: the
/// list, the running app, the prune). The full check runs off the click: in the staging keep, or for
/// a keep made at a click (the swap, an install) at the next launch (``sealPending()``).
nonisolated public struct KeptVersionStore: Sendable {
    public let root: URL
    /// The signing team of a bundle with a full check of every file (SecStaticCode in the app;
    /// injected in tests). Only a bundle kept without a record pays it.
    public let teamID: @Sendable (URL) -> String?
    /// The signing team of a bundle with the quick check a rollback makes at the click: the main
    /// executable and its Info.plist. Its resources are covered by the seal of the full check.
    public let quickTeamID: @Sendable (URL) -> String?
    /// The key that authenticates each record's sealed team (``KeptRecordKey``, a Keychain item only
    /// this app's signature reads); nil: no record is trusted, and every rollback checks every file.
    public let recordKey: @Sendable () -> SymmetricKey?
    /// The clock a keep records (tests set one).
    public var now: @Sendable () -> Date = { Date() }

    public init(root: URL, teamID: @escaping @Sendable (URL) -> String?, quickTeamID: (@Sendable (URL) -> String?)? = nil,
                recordKey: @escaping @Sendable () -> SymmetricKey? = { nil }) {
        self.root = root
        self.teamID = teamID
        self.quickTeamID = quickTeamID ?? teamID
        self.recordKey = recordKey
    }

    /// The name of the record beside a kept bundle.
    static let recordName = "kept.json"

    /// How a keep checks the copy's signature.
    public enum Check: Sendable {
        /// Every file, now, sealed: off the click (the staging keep).
        case full
        /// Not now: the copy goes without a sealed team, and ``sealPending()`` checks it at the next
        /// launch (a keep made at a click: the swap, an install that kept nothing earlier).
        case later
        /// The caller checked every file of `bundle` already and nothing can change it (a mounted,
        /// read-only disk image): the record's team stands, sealed on the copy.
        case checkedSource
    }

    /// Keeps `bundle` as `build`, then prunes to the `limit` kept most recently (nil: no prune, for
    /// a build downloaded to switch to, which may be older than every kept one). `record` is what is
    /// known about it (the schemas it reads, its date); the keep adds when it was kept and, by
    /// `check`, the team it is signed by.
    public func keep(bundle: URL, build: String, limit: Int?, record: KeptRecord? = nil, check: Check = .full) throws {
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
        written.seal(target, check: check, fullCheck: teamID, key: recordKey())
        // Best effort: without a record the next list checks the signature in full, as before.
        try? written.save(to: folder.appending(path: Self.recordName))
        if let limit { prune(limit: limit, keeping: build) }
    }

    /// Kept versions, newest build first. Without `teams` no signature is read (a prune, the card's
    /// label, a rollback before it picks): ``KeptVersion/teamID`` is the record's, unchecked; check
    /// the one a rollback takes with ``checkedTeam(of:)``.
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
            let team = teams ? checkedTeam(bundle: bundle, record: record) : record?.teamID
            return KeptVersion(build: info["CFBundleVersion"] as? String ?? build,
                               shortVersion: info["CFBundleShortVersionString"] as? String ?? build,
                               bundle: bundle, storeSchemas: plistSchemas ?? record?.storeSchemas, teamID: team,
                               keptAt: record?.keptAt, date: record?.date)
        }
        .sorted { Self.isNewer($0.build, than: $1.build) }
    }

    /// The team `kept` is signed by, checked for a rollback to it: the record's while the bundle's
    /// seal is the one taken around its full check, the record is one this app wrote (its MAC, by
    /// ``recordKey``) and the quick check of its executable agrees; else a full check of every file.
    public func checkedTeam(of kept: KeptVersion) -> String? {
        checkedTeam(bundle: kept.bundle, record: KeptRecord.read(from: kept.bundle.deletingLastPathComponent().appending(path: Self.recordName)))
    }

    private func checkedTeam(bundle: URL, record: KeptRecord?) -> String? {
        if let record, let recorded = record.teamID, let seal = record.seal, record.isAuthentic(key: recordKey()),
           seal == KeptSeal(bundle: bundle) {
            return quickTeamID(bundle) == recorded ? recorded : nil
        }
        return teamID(bundle)
    }

    /// Checks every file of each kept build kept without a sealed team (``Check/later``) and seals
    /// it, so going back to it later is quick. Run at launch, off the main thread; the builds it
    /// sealed. A build whose check fails is recorded as failed by `runningBuild` and not checked
    /// again until another build runs (a full check of a bundle that keeps failing would cost
    /// seconds at every launch); going back to it still checks every file at the click.
    public func sealPending(runningBuild: String) -> [String] {
        list(teams: false).compactMap { kept -> String? in
            let file = kept.bundle.deletingLastPathComponent().appending(path: Self.recordName)
            var record = KeptRecord.read(from: file) ?? KeptRecord(build: kept.build)
            guard record.seal == nil, record.sealFailedBy != runningBuild else { return nil }
            record.seal(kept.bundle, check: .full, fullCheck: teamID, key: recordKey())
            if record.seal == nil { record.sealFailedBy = runningBuild }
            guard (try? record.save(to: file)) != nil, record.seal != nil else { return nil }
            return kept.build
        }
    }

    /// Whether `kept` is still the bundle its record sealed: taken again right before the swap moves
    /// it into place, so nothing changed between the click's check and the rename goes in. True for a
    /// bundle with no seal (the click checked every file of it).
    public func stillSealed(_ kept: KeptVersion) -> Bool {
        let record = KeptRecord.read(from: kept.bundle.deletingLastPathComponent().appending(path: Self.recordName))
        guard let seal = record?.seal, record?.isAuthentic(key: recordKey()) == true else { return true }
        return seal == KeptSeal(bundle: kept.bundle)
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
