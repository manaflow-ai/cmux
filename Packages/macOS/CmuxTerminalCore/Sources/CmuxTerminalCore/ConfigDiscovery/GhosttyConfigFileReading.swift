public import Foundation

/// Filesystem seam used by ``GhosttyConfigDiscovery`` for every config-file read
/// it performs while resolving Ghostty config scan paths and scanning their
/// contents. Injecting this inverts the `FileManager.default` /
/// `String(contentsOfFile:)` globals the discovery logic used to reach for
/// directly, so tests can drive it against fixtures without touching the real
/// home directory.
///
/// The discovery logic runs synchronously on the launch path (inside the
/// Ghostty C-API config-load sequence) and on the test thread, so this seam is
/// intentionally not `Sendable`: it never crosses an actor or task boundary.
public protocol GhosttyConfigFileReading {
    /// Returns the byte size of the file at `path`, or `nil` when it does not
    /// exist or its attributes cannot be read.
    func fileSize(atPath path: String) -> Int?

    /// Returns the UTF-8 contents of the file at `path`, or `nil` when it cannot
    /// be read.
    func contents(atPath path: String) -> String?
}

/// Default ``GhosttyConfigFileReading`` conformer backed by a `FileManager`.
///
/// Reads file sizes through `FileManager.attributesOfItem(atPath:)` and file
/// contents through `String(contentsOfFile:encoding:)`, byte-identical to the
/// inline reads the discovery logic previously performed in the app target.
public struct FileManagerGhosttyConfigFileReader: GhosttyConfigFileReading {
    private let fileManager: FileManager

    /// Creates a reader backed by the given `FileManager` (defaults to
    /// `FileManager.default`).
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func fileSize(atPath path: String) -> Int? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    public func contents(atPath path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}
