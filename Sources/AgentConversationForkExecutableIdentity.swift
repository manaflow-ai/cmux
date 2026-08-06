import CryptoKit
import Darwin
import Foundation

/// Stable identity of a harness executable. Explicit validation also records
/// the SHA-256 capability of the exact bytes copied and probed by cmux.
struct AgentConversationForkExecutableIdentity: Equatable, Hashable, Sendable {
    static let maximumArtifactBytes: Int64 = 512 * 1_024 * 1_024

    let lookupPath: String
    let realPath: String
    let fingerprint: String
    let device: UInt64
    let shellStatSignature: String
    let contentSHA256: String?

    static func capture(
        executablePath: String,
        runtimeSearchPath: String?,
        hashContents: Bool = false,
        deadline: ContinuousClock.Instant? = nil
    ) -> Self? {
        var environment: [String: String] = [:]
        if let runtimeSearchPath,
           !runtimeSearchPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environment["PATH"] = runtimeSearchPath
        }
        guard let identity = AgentForkSupport.forkProbeExecutableIdentity(
            executable: executablePath,
            processEnvironment: environment,
            workingDirectory: nil
        ) else {
            return nil
        }
        guard let captured = capturedFile(
            atPath: identity.realPath,
            hashContents: hashContents,
            deadline: deadline
        ) else {
            return nil
        }
        let status = captured.metadata
        let device = UInt64(status.st_dev)
        let shellStatSignature = [
            String(device),
            String(status.st_ino),
            String(status.st_mode, radix: 8),
            String(status.st_size),
            String(status.st_mtimespec.tv_sec),
            String(status.st_mtimespec.tv_nsec),
            String(status.st_ctimespec.tv_sec),
            String(status.st_ctimespec.tv_nsec),
        ].joined(separator: ":")
        return Self(
            lookupPath: identity.lookupPath,
            realPath: identity.realPath,
            fingerprint: identity.cachePart,
            device: device,
            shellStatSignature: shellStatSignature,
            contentSHA256: captured.contentSHA256
        )
    }

    static func contentSHA256(
        atPath path: String,
        deadline: ContinuousClock.Instant? = nil
    ) -> String? {
        capturedFile(
            atPath: path,
            hashContents: true,
            deadline: deadline
        )?.contentSHA256
    }

    private static func capturedFile(
        atPath path: String,
        hashContents: Bool,
        deadline: ContinuousClock.Instant?
    ) -> (metadata: stat, contentSHA256: String?)? {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var initialMetadata = stat()
        guard Darwin.fstat(descriptor, &initialMetadata) == 0,
              initialMetadata.st_mode & S_IFMT == S_IFREG,
              initialMetadata.st_size >= 0,
              initialMetadata.st_size <= maximumArtifactBytes,
              workMayContinue(deadline: deadline) else {
            return nil
        }

        let contentSHA256: String?
        if hashContents {
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                guard workMayContinue(deadline: deadline) else { return nil }
                let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if bytesRead < 0, errno == EINTR { continue }
                guard bytesRead >= 0 else { return nil }
                if bytesRead == 0 { break }
                hasher.update(data: Data(buffer.prefix(bytesRead)))
            }
            contentSHA256 = hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
        } else {
            contentSHA256 = nil
        }

        var finalMetadata = stat()
        var pathMetadata = stat()
        guard Darwin.fstat(descriptor, &finalMetadata) == 0,
              Darwin.lstat(path, &pathMetadata) == 0,
              stableMetadata(initialMetadata, finalMetadata),
              stableMetadata(finalMetadata, pathMetadata),
              workMayContinue(deadline: deadline) else {
            return nil
        }
        return (finalMetadata, contentSHA256)
    }

    private static func stableMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    static func workMayContinue(
        deadline: ContinuousClock.Instant?
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let deadline else { return true }
        return ContinuousClock().now < deadline
    }
}
