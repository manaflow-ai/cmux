import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Upload partials on disk, keyed by device install + sha256 + size, so a
/// reconnecting device resumes where the Mac's bytes end (c4-files.md
/// section 4). One live upload per key; a second open is refused retryable.
actor UploadStaging {
    struct Claim: Sendable {
        let key: String
        let path: String
        let uploadID: String
    }

    private let configuration: MobileFilesConfiguration
    /// Claimed partial paths by key.
    private var claimed: [String: String] = [:]

    init(configuration: MobileFilesConfiguration) {
        self.configuration = configuration
    }

    /// Claims the partial for one upload and returns its path. Prunes expired
    /// partials of the device first and checks its quota and free disk.
    func claim(install: String, sha256: String, size: UInt64) throws(MobileDaemonError) -> Claim {
        let directory = configuration.stagingDirectory.path + "/" + String(FileDigest.hex(of: install).prefix(24))
        let key = FileDigest.hex(of: "\(install)|\(sha256)|\(size)")
        guard claimed[key] == nil else {
            throw MobileDaemonError(code: "validation.invalid", message: "this upload is already in progress", retryable: true)
        }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw MobileDaemonError(code: "owner.unreachable", message: "upload staging is unavailable", retryable: true)
        }
        let path = directory + "/\(sha256)-\(size).part"
        let others = prune(directory, keeping: path)
        guard others + size <= configuration.stagingQuotaBytes else { throw .filesTooLarge("quota") }
        let existing = Self.length(of: path) ?? 0
        if let free = Self.freeBytes(directory), free < (size - min(existing, size)) + configuration.freeSpaceMarginBytes {
            throw .filesTooLarge("disk")
        }
        claimed[key] = path
        return Claim(key: key, path: path, uploadID: "up_" + String(key.prefix(16)))
    }

    func release(_ claim: Claim) {
        claimed[claim.key] = nil
    }

    /// Removes expired partials in `directory` and returns the bytes of the
    /// remaining ones other than `keeping`.
    private func prune(_ directory: String, keeping: String) -> UInt64 {
        let cutoff = Date().addingTimeInterval(-configuration.partialLifetime)
        var total: UInt64 = 0
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names where name.hasSuffix(".part") {
            let path = directory + "/" + name
            guard path != keeping else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast
            if modified < cutoff, !claimed.values.contains(path) {
                try? FileManager.default.removeItem(atPath: path)
            } else {
                total += (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            }
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
