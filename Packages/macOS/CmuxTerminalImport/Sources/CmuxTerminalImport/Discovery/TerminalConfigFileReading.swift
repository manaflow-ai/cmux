public import Foundation

/// Reads config files and lists directories for detection and includes.
///
/// Injected so tests read fixtures and never the user's home directory.
public protocol TerminalConfigFileReading: Sendable {
    /// The file's UTF-8 contents, or `nil` when it cannot be read.
    ///
    /// - Parameter url: The file to read.
    func contents(of url: URL) -> String?

    /// The regular files directly inside a directory, or an empty list.
    ///
    /// - Parameter url: The directory to list.
    func files(in url: URL) -> [URL]
}

/// Reads config files from disk.
public struct DiskTerminalConfigFileReader: TerminalConfigFileReading {
    /// Creates a reader.
    public init() {}

    /// The file's UTF-8 contents, or `nil` when it is missing or unreadable.
    public func contents(of url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// The regular files in a directory, sorted by name.
    public func files(in url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
