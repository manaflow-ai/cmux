import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Upload partials on disk, keyed by device install + sha256 + size, so a
/// reconnecting device resumes where the Mac's bytes end (c4-files.md
/// section 4). One live upload per key: a new open of the same key aborts
/// the old channel (a dead session the Mac has not noticed yet) and waits
/// for it to let go. Bytes still to be written by live claims are reserved
/// against the device quota and free disk, so parallel opens cannot
/// overcommit. A placed upload is remembered so a reopen after a lost
/// `files.upload.done` gets the same path instead of a duplicate.
actor UploadStaging {
    struct Claim: Sendable {
        let key: String
        let token: UUID
        let path: String
        let uploadID: String
        /// Set when this exact upload was already placed (idempotent reopen).
        let placed: String?
    }

    private struct Live {
        let token: UUID
        let path: String
        let install: String
        let reserved: UInt64
        let abort: @Sendable () async -> Void
        var waiters: [CheckedContinuation<Void, Never>]
    }

    static let rememberedPlacements = 256

    private let configuration: MobileFilesConfiguration
    private var live: [String: Live] = [:]
    private var placed: [String: String] = [:]
    private var placedOrder: [String] = []

    init(configuration: MobileFilesConfiguration) {
        self.configuration = configuration
    }

    /// Claims the partial for one upload. `abort` closes this claim's channel
    /// when a newer open of the same upload preempts it.
    func claim(install: String, sha256: String, size: UInt64,
               abort: @escaping @Sendable () async -> Void) async throws(MobileDaemonError) -> Claim {
        let key = FileDigest.hex(of: "\(install)|\(sha256)|\(size)")
        let uploadID = "up_" + String(key.prefix(16))
        while let old = live[key] {
            await old.abort()
            if live[key]?.token == old.token {
                await withCheckedContinuation { continuation in live[key]?.waiters.append(continuation) }
            }
        }
        if let path = placed[key], UploadStaging.length(of: path) == size {
            let token = UUID()
            live[key] = Live(token: token, path: path, install: install, reserved: 0, abort: abort, waiters: [])
            return Claim(key: key, token: token, path: path, uploadID: uploadID, placed: path)
        }
        let directory = deviceDirectory(install)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw MobileDaemonError(code: "owner.unreachable", message: "upload staging is unavailable", retryable: true)
        }
        let path = directory + "/\(sha256)-\(size).part"
        pruneExpired()
        let existing = min(Self.length(of: path) ?? 0, size)
        let remaining = size - existing
        let othersOnDisk = Self.partialBytes(in: directory, excluding: path)
        let reservedByOthers = live.values.filter { $0.install == install }.reduce(UInt64(0)) { $0 + $1.reserved }
        guard othersOnDisk + reservedByOthers + size <= configuration.stagingQuotaBytes else { throw .filesTooLarge("quota") }
        let reservedEverywhere = live.values.reduce(UInt64(0)) { $0 + $1.reserved }
        if let free = Self.freeBytes(directory), free < remaining + reservedEverywhere + configuration.freeSpaceMarginBytes {
            throw .filesTooLarge("disk")
        }
        let token = UUID()
        live[key] = Live(token: token, path: path, install: install, reserved: remaining, abort: abort, waiters: [])
        return Claim(key: key, token: token, path: path, uploadID: uploadID, placed: nil)
    }

    func release(_ claim: Claim) {
        guard let entry = live[claim.key], entry.token == claim.token else { return }
        live[claim.key] = nil
        for waiter in entry.waiters { waiter.resume() }
    }

    /// Records where a verified upload landed.
    func placed(_ claim: Claim, at path: String) {
        placed[claim.key] = path
        placedOrder.append(claim.key)
        if placedOrder.count > Self.rememberedPlacements {
            placed[placedOrder.removeFirst()] = nil
        }
    }

    /// Bytes still free for this claim on the staging volume beyond the margin.
    func hasRoom(for bytes: UInt64, path: String) -> Bool {
        guard let free = Self.freeBytes((path as NSString).deletingLastPathComponent) else { return true }
        return free >= bytes + configuration.freeSpaceMarginBytes
    }

    private func deviceDirectory(_ install: String) -> String {
        configuration.stagingDirectory.path + "/" + String(FileDigest.hex(of: install).prefix(24))
    }

    /// Removes expired partials of every device (revoked devices included).
    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-configuration.partialLifetime)
        let root = configuration.stagingDirectory.path
        let claimedPaths = Set(live.values.map(\.path))
        for device in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let directory = root + "/" + device
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".part") {
                let path = directory + "/" + name
                guard !claimedPaths.contains(path) else { continue }
                let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
                if modified < cutoff { try? FileManager.default.removeItem(atPath: path) }
            }
        }
    }

    static func partialBytes(in directory: String, excluding: String) -> UInt64 {
        var total: UInt64 = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".part") {
            let path = directory + "/" + name
            if path != excluding { total += length(of: path) ?? 0 }
        }
        return total
    }

    static func length(of path: String) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return UInt64(info.st_size)
    }

    static func freeBytes(_ path: String) -> UInt64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return UInt64(max(0, capacity))
    }
}
