import Darwin
import Foundation

/// The production ``SSHConfigFileReading`` implementation backed by the local
/// filesystem.
///
/// Reads only regular files (a FIFO or device at a config path is skipped
/// rather than blocking the caller) and expands globs with `glob(3)`, matching
/// how OpenSSH resolves `Include` arguments.
public struct SSHConfigFileSystemReader: SSHConfigFileReading {
    /// Creates a filesystem-backed reader.
    public init() {}

    /// Returns the UTF-8 contents of the regular file at `path`, or `nil`.
    ///
    /// - Parameter path: An absolute file path.
    /// - Returns: The decoded contents, or `nil` for missing files, non-regular
    ///   files, or undecodable data.
    public func contentsOfFile(atPath path: String) -> String? {
        var status = stat()
        guard stat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Expands `pattern` with `glob(3)`.
    ///
    /// - Parameter pattern: An absolute path that may contain `*` or `?`.
    /// - Returns: Matching absolute paths in `glob(3)`'s sorted order.
    public func filePaths(matchingGlob pattern: String) -> [String] {
        var results = glob_t()
        defer { globfree(&results) }
        guard glob(pattern, 0, nil, &results) == 0 else { return [] }
        var paths: [String] = []
        paths.reserveCapacity(Int(results.gl_pathc))
        for index in 0..<Int(results.gl_pathc) {
            if let cString = results.gl_pathv[index] {
                paths.append(String(cString: cString))
            }
        }
        return paths
    }
}
