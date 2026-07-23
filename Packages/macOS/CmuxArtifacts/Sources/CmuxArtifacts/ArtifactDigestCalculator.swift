import Darwin
import CryptoKit
import Foundation

/// Computes bounded-file SHA-256 identities for deduplication.
struct ArtifactDigestCalculator: Sendable {
    private let chunkSize = 64 * 1024

    func digest(url: URL, expectedSize: Int64, allowedRoot: URL) throws -> String {
        try Task.checkCancellation()
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw ArtifactStoreError.sourceNotRegularFile(url.path)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              status.st_size == expectedSize else {
            throw ArtifactStoreError.sourceNotRegularFile(url.path)
        }
        guard let descriptorURL = descriptorURL(descriptor),
              ArtifactPathResolver().relativePath(descriptorURL, root: allowedRoot) != nil else {
            throw ArtifactStoreError.pathOutsideStore(url.path)
        }

        var remaining = expectedSize
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = min(chunkSize, Int(remaining))
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ArtifactStoreError.sourceNotRegularFile(url.path)
            }
            guard count > 0 else {
                throw ArtifactStoreError.sourceNotRegularFile(url.path)
            }
            hasher.update(data: Data(buffer.prefix(count)))
            remaining -= Int64(count)
        }

        var extraByte: UInt8 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &extraByte, 1)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            throw ArtifactStoreError.sourceNotRegularFile(url.path)
        }

        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        let digest = hasher.finalize()
        var encoded: [UInt8] = []
        encoded.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private func descriptorURL(_ descriptor: Int32) -> URL? {
        var descriptorInfo = vnode_fdinfowithpath()
        let result = proc_pidfdinfo(
            Darwin.getpid(),
            descriptor,
            PROC_PIDFDVNODEPATHINFO,
            &descriptorInfo,
            Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        )
        guard result > 0 else { return nil }
        let path = withUnsafeBytes(of: &descriptorInfo.pvip.vip_path) { rawBuffer -> String in
            guard let baseAddress = rawBuffer.baseAddress else { return "" }
            return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
        }
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: false)
    }
}
