import Darwin
public import Foundation

/// Reads bounded local status-icon files without following path changes between validation and reading.
public struct SidebarStatusIconFileReader: Sendable {
    /// Creates a local status-icon file reader.
    public init() {}

    /// Opens, validates, and reads one regular file through the same descriptor.
    ///
    /// - Parameters:
    ///   - path: An absolute, standardized filesystem path.
    ///   - maximumByteCount: The largest accepted file size.
    /// - Returns: The file data, or `nil` when the path is not a bounded regular file.
    public func data(at path: String, maximumByteCount: Int) -> Data? {
        guard maximumByteCount > 0 else { return nil }
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0,
              metadata.st_size <= maximumByteCount else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumByteCount + 1))
        while data.count <= maximumByteCount {
            let remaining = maximumByteCount + 1 - data.count
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(buffer, count: bytesRead)
        }
        guard !data.isEmpty, data.count <= maximumByteCount else { return nil }
        return data
    }
}
