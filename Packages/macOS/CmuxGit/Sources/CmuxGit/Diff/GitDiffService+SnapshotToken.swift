internal import CryptoKit
internal import Foundation

extension GitDiffService {
    struct SnapshotContext: Equatable, Sendable {
        let baselineObjectID: String
        let indexIdentity: FileSystemIdentity
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
              let rawPath = removingGitLineTerminator(output),
              !rawPath.isEmpty else { return .failed }
        let indexPath: String
        if rawPath.hasPrefix("/") {
            indexPath = rawPath
        } else {
            indexPath = URL(fileURLWithPath: repoRoot, isDirectory: true)
                .appendingPathComponent(rawPath)
                .standardizedFileURL.path
        }
        let indexIdentity: FileSystemIdentity
        switch fileSystemIdentitiesResult(paths: [indexPath], allowMissing: true) {
        case .success(let identities):
            guard let identity = identities.first else { return .failed }
            indexIdentity = identity
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        return .success(
            SnapshotContext(
                baselineObjectID: baselineObjectID,
                indexIdentity: indexIdentity
            )
        )
    }

    func snapshotFileIdentitiesResult(
        repoRoot: String,
        summaries: [GitDiffSummary]
    ) -> GitDiffQueryResult<[FileSystemIdentity]> {
        let rootURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
        let existingPaths = summaries.compactMap { summary in
            summary.status == .deleted
                ? nil
                : rootURL.appendingPathComponent(summary.path).path
        }
        let deletedPaths = summaries.compactMap { summary in
            summary.status == .deleted
                ? rootURL.appendingPathComponent(summary.path).path
                : nil
        }
        let existingIdentities: [FileSystemIdentity]
        switch fileSystemIdentitiesResult(paths: existingPaths, allowMissing: true) {
        case .success(let identities):
            existingIdentities = identities
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        let deletedIdentities: [FileSystemIdentity]
        switch fileSystemIdentitiesResult(paths: deletedPaths, allowMissing: true) {
        case .success(let identities):
            deletedIdentities = identities
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        var identityIterator = existingIdentities.makeIterator()
        var deletedIdentityIterator = deletedIdentities.makeIterator()
        var identities: [FileSystemIdentity] = []
        identities.reserveCapacity(summaries.count)
        for summary in summaries {
            guard !Task.isCancelled else { return .failed }
            if summary.status == .deleted {
                guard let identity = deletedIdentityIterator.next() else { return .failed }
                identities.append(identity)
            } else {
                guard let identity = identityIterator.next() else { return .failed }
                identities.append(identity)
            }
        }
        guard identityIterator.next() == nil,
              deletedIdentityIterator.next() == nil else { return .failed }
        return .success(identities)
    }

    func snapshotTokens(
        context: SnapshotContext,
        summaries: [GitDiffSummary],
        identities: [FileSystemIdentity],
        semanticIdentities: [Data?]
    ) -> [String]? {
        guard summaries.count == identities.count,
              summaries.count == semanticIdentities.count else { return nil }
        return zip(zip(summaries, identities), semanticIdentities).map { pair, semanticIdentity in
            snapshotToken(
                context: context,
                summary: pair.0,
                currentIdentity: pair.1,
                semanticIdentity: semanticIdentity
            )
        }
    }

    private func snapshotToken(
        context: SnapshotContext,
        summary: GitDiffSummary,
        currentIdentity: FileSystemIdentity,
        semanticIdentity: Data?
    ) -> String {
        var payload = Data()
        append(context.baselineObjectID, to: &payload)
        append(context.indexIdentity, to: &payload)
        append(summary.path, to: &payload)
        append(summary.oldPath, to: &payload)
        append(summary.status.rawValue, to: &payload)
        append(summary.additions, to: &payload)
        append(summary.deletions, to: &payload)
        append(currentIdentity, to: &payload)
        append(semanticIdentity, to: &payload)
        return hexEncoded(SHA256.hash(data: payload))
    }

    private static let missingFileSystemIdentity = FileSystemIdentity(
        device: 0,
        inode: 0,
        mode: 0,
        size: 0,
        modificationTime: "",
        changeTime: ""
    )

    private func fileSystemIdentitiesResult(
        paths: [String],
        allowMissing: Bool
    ) -> GitDiffQueryResult<[FileSystemIdentity]> {
        guard !paths.isEmpty else { return .success([]) }
        let maxOutputBytes = paths.count * 160 + 1024
        let result = processRunner.runFileSystemStat(
            paths: paths,
            allowMissing: allowMissing,
            maxOutputBytes: maxOutputBytes,
            deadlineSeconds: remainingOperationDeadlineSeconds
        )
        if let failure: GitDiffQueryResult<[FileSystemIdentity]> = queryFailure(from: result) {
            return failure
        }
        guard let output = result.successOutput, !result.capped else { return .failed }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count == paths.count else { return .failed }
        var identities: [FileSystemIdentity] = []
        identities.reserveCapacity(lines.count)
        for line in lines {
            if line == "missing" {
                guard allowMissing else { return .failed }
                identities.append(Self.missingFileSystemIdentity)
                continue
            }
            guard let identity = parseFileSystemIdentity(line) else { return .failed }
            identities.append(identity)
        }
        return .success(identities)
    }

    private func parseFileSystemIdentity(_ line: Substring) -> FileSystemIdentity? {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 6,
              let device = UInt64(fields[0]),
              let inode = UInt64(fields[1]),
              let mode = UInt32(fields[2], radix: 8),
              let size = Int64(fields[3]) else { return nil }
        return FileSystemIdentity(
            device: device,
            inode: inode,
            mode: mode,
            size: size,
            modificationTime: String(fields[4]),
            changeTime: String(fields[5])
        )
    }

    private func append(_ value: String?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        append(UInt64(value.utf8.count), to: &data)
        data.append(contentsOf: value.utf8)
    }

    private func append(_ value: Int?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        append(UInt64(bitPattern: Int64(value)), to: &data)
    }

    private func append(_ value: Data?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        append(UInt64(value.count), to: &data)
        data.append(value)
    }

    private func append(_ value: FileSystemIdentity, to data: inout Data) {
        append(value.device, to: &data)
        append(value.inode, to: &data)
        append(UInt64(value.mode), to: &data)
        append(UInt64(bitPattern: value.size), to: &data)
        append(value.modificationTime, to: &data)
        append(value.changeTime, to: &data)
    }

    private func append(_ value: UInt64, to data: inout Data) {
        data.append(UInt8((value >> 56) & 0xff))
        data.append(UInt8((value >> 48) & 0xff))
        data.append(UInt8((value >> 40) & 0xff))
        data.append(UInt8((value >> 32) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private func hexEncoded<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
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
