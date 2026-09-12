import Darwin
import Foundation

/// Bounded file reader used by the repository and content-search paths.
struct ArtifactByteReader {
    let fileManager: FileManager

    /// Reads a regular file without following a final symbolic link.
    func data(at url: URL, maximumBytes: Int64) throws -> Data {
        guard maximumBytes > 0 else { return Data() }
        guard fileManager.fileExists(atPath: url.path) else {
            throw ArtifactStoreError.sourceUnavailable(url.path)
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ArtifactStoreError.sourceUnavailable(url.path) }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw ArtifactStoreError.sourceUnavailable(url.path)
        }
        let size = Int64(status.st_size)
        guard size <= maximumBytes else {
            throw ArtifactStoreError.fileTooLarge(actual: size, limit: maximumBytes)
        }
        var output = Data()
        output.reserveCapacity(Int(size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, Int(maximumBytes) + 1))
        while output.count <= Int(maximumBytes) {
            try Task.checkCancellation()
            let requested = min(buffer.count, Int(maximumBytes) + 1 - output.count)
            guard requested > 0 else { break }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ArtifactStoreError.sourceUnavailable(url.path)
            }
            output.append(contentsOf: buffer.prefix(count))
        }
        guard Int64(output.count) <= maximumBytes else {
            throw ArtifactStoreError.fileTooLarge(actual: Int64(output.count), limit: maximumBytes)
        }
        return output
    }
}
