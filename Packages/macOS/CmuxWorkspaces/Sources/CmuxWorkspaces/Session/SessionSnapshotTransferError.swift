public import Foundation

/// Why a snapshot file could not be imported into the running app.
///
/// Every case carries the file that was inspected so the app can name it in
/// the user-facing message.
public enum SessionSnapshotImportError: Error, Equatable, Sendable {
    /// No file exists at the location.
    case fileNotFound(URL)
    /// The file exists but could not be read.
    case unreadable(URL)
    /// The file is not a cmux session snapshot (not JSON, no `version`, or
    /// the payload does not decode at the current schema).
    case notASessionSnapshot(URL)
    /// The snapshot was written by a newer cmux with a schema this build
    /// cannot read.
    case newerSchemaVersion(URL, found: Int, supported: Int)
    /// The snapshot uses an older schema this build no longer reads.
    case olderSchemaVersion(URL, found: Int, supported: Int)
    /// The snapshot decodes but has no windows to restore.
    case noWindows(URL)

    /// The file the error refers to.
    public var fileURL: URL {
        switch self {
        case .fileNotFound(let url),
             .unreadable(let url),
             .notASessionSnapshot(let url),
             .newerSchemaVersion(let url, _, _),
             .olderSchemaVersion(let url, _, _),
             .noWindows(let url):
            return url
        }
    }
}

/// Why the saved snapshot could not be exported to a file.
public enum SessionSnapshotExportError: Error, Equatable, Sendable {
    /// Neither the primary snapshot nor its backup holds a usable snapshot.
    case noSnapshot
    /// The destination already exists and overwriting was not requested.
    case destinationExists(URL)
    /// The destination is one of this install's own snapshot files.
    case destinationIsLiveSnapshot(URL)
    /// Writing the destination failed.
    case writeFailed(URL)
}

/// A snapshot validated for import, with the file it was read from.
public struct SessionSnapshotImport<SnapshotValue: SessionSnapshotRepresenting>: Sendable {
    /// The decoded snapshot.
    public let snapshot: SnapshotValue
    /// The file the snapshot was read from.
    public let fileURL: URL

    /// Creates an import result.
    public init(snapshot: SnapshotValue, fileURL: URL) {
        self.snapshot = snapshot
        self.fileURL = fileURL
    }
}
