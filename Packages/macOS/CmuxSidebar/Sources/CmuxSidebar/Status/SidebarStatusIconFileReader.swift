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
        guard let file = openFile(at: path, maximumByteCount: maximumByteCount) else { return nil }
        return file.data(maximumByteCount: maximumByteCount)
    }

    /// Opens and validates one regular file while retaining ownership of the checked descriptor.
    func openFile(at path: String, maximumByteCount: Int) -> SidebarStatusIconOpenFile? {
        guard maximumByteCount > 0, maximumByteCount < Int.max else { return nil }
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0,
              metadata.st_size <= maximumByteCount else {
            Darwin.close(descriptor)
            return nil
        }
        return SidebarStatusIconOpenFile(descriptor: descriptor, metadata: metadata)
    }
}
