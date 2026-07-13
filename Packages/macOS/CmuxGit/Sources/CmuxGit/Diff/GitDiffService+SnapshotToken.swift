internal import CryptoKit
internal import Darwin
internal import Foundation

extension GitDiffService {
    struct SnapshotContext: Equatable, Sendable {
        let baselineObjectID: String
        let indexIdentity: FileSystemIdentity
    }

    struct FileSystemIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    func snapshotContextResult(
        repoRoot: String,
        baselineObjectID: String
    ) -> GitDiffQueryResult<SnapshotContext> {
        let indexPathResult = runGit(
            in: repoRoot,
            arguments: ["rev-parse", "--git-path", "index"],
            maxOutputBytes: 64 * 1024
        )
        if let failure: GitDiffQueryResult<SnapshotContext> = queryFailure(from: indexPathResult) {
            return failure
        }
        guard let output = indexPathResult.successOutput,
              !indexPathResult.capped,
              let rawPath = Self.removingGitLineTerminator(output),
              !rawPath.isEmpty else { return .failed }
        let indexPath: String
        if rawPath.hasPrefix("/") {
            indexPath = rawPath
        } else {
            indexPath = URL(fileURLWithPath: repoRoot, isDirectory: true)
                .appendingPathComponent(rawPath)
                .standardizedFileURL.path
        }
        guard let indexIdentity = Self.fileSystemIdentity(atPath: indexPath) else {
            // An absent index is valid for a repository with no staged files.
            guard errno == ENOENT || errno == ENOTDIR else { return .failed }
            return .success(
                SnapshotContext(
                    baselineObjectID: baselineObjectID,
                    indexIdentity: Self.missingFileSystemIdentity
                )
            )
        }
        return .success(
            SnapshotContext(
                baselineObjectID: baselineObjectID,
                indexIdentity: indexIdentity
            )
        )
    }

    func snapshotTokenResult(
        repoRoot: String,
        context: SnapshotContext,
        summary: GitDiffSummary
    ) -> GitDiffQueryResult<String> {
        let rootURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
        let currentIdentity = Self.fileSystemIdentityOrMissing(
            atPath: rootURL.appendingPathComponent(summary.path).path
        )
        guard case .success(let currentIdentity) = currentIdentity else {
            return .failed
        }
        let oldIdentity: FileSystemIdentity
        if let oldPath = summary.oldPath {
            switch Self.fileSystemIdentityOrMissing(
                atPath: rootURL.appendingPathComponent(oldPath).path
            ) {
            case .success(let identity):
                oldIdentity = identity
            case .notFound, .failed, .timedOut:
                return .failed
            }
        } else {
            oldIdentity = Self.missingFileSystemIdentity
        }

        var payload = Data()
        Self.append(context.baselineObjectID, to: &payload)
        Self.append(context.indexIdentity, to: &payload)
        Self.append(summary.path, to: &payload)
        Self.append(summary.oldPath, to: &payload)
        Self.append(summary.status.rawValue, to: &payload)
        Self.append(summary.additions, to: &payload)
        Self.append(summary.deletions, to: &payload)
        Self.append(currentIdentity, to: &payload)
        Self.append(oldIdentity, to: &payload)
        return .success(Self.hexEncoded(SHA256.hash(data: payload)))
    }

    private static let missingFileSystemIdentity = FileSystemIdentity(
        device: 0,
        inode: 0,
        mode: 0,
        size: 0,
        modificationSeconds: 0,
        modificationNanoseconds: 0,
        changeSeconds: 0,
        changeNanoseconds: 0
    )

    private static func fileSystemIdentityOrMissing(
        atPath path: String
    ) -> GitDiffQueryResult<FileSystemIdentity> {
        if let identity = fileSystemIdentity(atPath: path) {
            return .success(identity)
        }
        return errno == ENOENT || errno == ENOTDIR
            ? .success(missingFileSystemIdentity)
            : .failed
    }

    private static func fileSystemIdentity(atPath path: String) -> FileSystemIdentity? {
        var value = stat()
        guard lstat(path, &value) == 0 else { return nil }
        return FileSystemIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt32(value.st_mode),
            size: Int64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }

    private static func append(_ value: String?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        append(UInt64(value.utf8.count), to: &data)
        data.append(contentsOf: value.utf8)
    }

    private static func append(_ value: Int?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        append(UInt64(bitPattern: Int64(value)), to: &data)
    }

    private static func append(_ value: FileSystemIdentity, to data: inout Data) {
        append(value.device, to: &data)
        append(value.inode, to: &data)
        append(UInt64(value.mode), to: &data)
        append(UInt64(bitPattern: value.size), to: &data)
        append(UInt64(bitPattern: value.modificationSeconds), to: &data)
        append(UInt64(bitPattern: value.modificationNanoseconds), to: &data)
        append(UInt64(bitPattern: value.changeSeconds), to: &data)
        append(UInt64(bitPattern: value.changeNanoseconds), to: &data)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        data.append(UInt8((value >> 56) & 0xff))
        data.append(UInt8((value >> 48) & 0xff))
        data.append(UInt8((value >> 40) & 0xff))
        data.append(UInt8((value >> 32) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func hexEncoded<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let alphabet = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(digest.underestimatedCount * 2)
        for byte in digest {
            encoded.append(alphabet[Int(byte >> 4)])
            encoded.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
