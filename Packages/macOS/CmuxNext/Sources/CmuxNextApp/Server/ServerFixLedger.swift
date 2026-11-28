import CmuxNextServerHelper
import Foundation

/// The app's own record of the fixes the helper applied for it, so Stop
/// Serving knows whether it needs the helper at all (plans/cmux-next/server.md
/// 9.4). The helper's record is root-only; this one is the app's: a 0600 JSON
/// file in the app's support folder, written atomically, keyed by fix id.
/// A missing file is an empty ledger; a file that cannot be read is
/// `.unknown`, and one that names a fix this build does not know is
/// `.foreign`. Callers treat both as "every fix may be applied" (fail safe).
nonisolated struct ServerFixLedger: Sendable {
    nonisolated enum Contents: Sendable, Equatable {
        case fixes(Set<ServerFix>)
        /// The file cannot be read.
        case unknown
        /// The file names a fix this build cannot revert (a newer build's);
        /// only that build may empty it.
        case foreign

        /// The fixes to revert, in allowlist order; every fix when not known.
        var toRevert: [ServerFix] {
            switch self {
            case let .fixes(set): ServerFix.allCases.filter(set.contains)
            case .unknown, .foreign: ServerFix.allCases
            }
        }
    }

    private nonisolated struct File: Codable {
        var version = 1
        /// Fix id -> apply time in ms since 1970.
        var fixes: [String: Int64] = [:]
    }

    let url: URL

    /// `~/Library/Application Support/cmux/server-fix-ledger/<helper label>.json`:
    /// keyed by this build's helper label (`<bundle id>.server-helper`), as
    /// each build (DEV and NIGHTLY tags too) has its own helper. It outlives
    /// app restarts; only reverts remove entries.
    static var standard: ServerFixLedger {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let label = Bundle.main.bundleIdentifier.flatMap { ServerHelperConstants().machServiceName(appBundleID: $0) }
            ?? "cmux.server-helper"
        return ServerFixLedger(url: support.appendingPathComponent("cmux/server-fix-ledger/\(label).json"))
    }

    @concurrent func load() async -> Contents {
        guard FileManager.default.fileExists(atPath: url.path) else { return .fixes([]) }
        // concurrency-allow: @concurrent, off the main actor; a small file
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            return .unknown
        }
        // An id this build does not know may be a fix it cannot name: fail safe.
        let fixes = file.fixes.keys.map(ServerFix.init(rawValue:))
        guard fixes.allSatisfy({ $0 != nil }) else { return .foreign }
        return .fixes(Set(fixes.compactMap { $0 }))
    }

    /// Adds a fix before the helper is asked to apply it (a timed-out call may
    /// still have changed the setting). A ledger that cannot be read stays as
    /// it is (still `.unknown`, so nothing is lost); foreign ids are kept.
    @concurrent func record(_ fix: ServerFix) async throws {
        guard await load() != .unknown else { return }
        var file = try readKnown()
        if file.fixes[fix.rawValue] == nil {
            file.fixes[fix.rawValue] = Int64(Date().timeIntervalSince1970 * 1000)
        }
        try write(file)
    }

    /// Removes a fix after its revert succeeded or the helper had nothing to revert.
    @concurrent func clear(_ fix: ServerFix) async throws {
        guard await load() != .unknown else { return }
        var file = try readKnown()
        guard file.fixes.removeValue(forKey: fix.rawValue) != nil else { return }
        try write(file)
    }

    /// Replaces any content (also an unreadable file) with an empty ledger:
    /// after every fix was reverted. Never for a `.foreign` ledger.
    @concurrent func reset() async throws {
        try write(File())
    }

    private func readKnown() throws -> File {
        guard FileManager.default.fileExists(atPath: url.path) else { return File() }
        // concurrency-allow: called only from the @concurrent members above
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    /// A new temp file created 0600 (`O_CREAT | O_EXCL`, so it is never
    /// readable by others, not even briefly), written in full, then renamed
    /// over the ledger.
    private func write(_ file: File) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(file)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(temp.path)
            throw error
        }
    }
}
