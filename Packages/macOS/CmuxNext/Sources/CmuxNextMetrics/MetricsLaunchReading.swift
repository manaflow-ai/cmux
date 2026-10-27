public import Foundation

/// Reads one launch's metrics file (task 052's store) for ``MetricsLaunchFold``: the system profile in its
/// header and the samples that launch had not uploaded yet (each bucket minus its logged shadow).
///
/// The fold never reads a file through anything else, so the file layout stays the store's
/// (``MetricsLaunchFileReader`` reads ``MetricsStore``'s files).
public protocol MetricsLaunchReading: Sendable {
    /// What a launch's file holds: its profile (version, build, channel, OS, hardware class, boot session), its
    /// unsent samples and the source launch's id. The id comes from the file's header (boot session, start time,
    /// pid), not from the file's name: pids are reused, so two launches can leave files with the same name.
    associatedtype Contents: Sendable & Identifiable where Contents.ID == String

    /// Whether `file` is a launch's metrics file of this process kind (not the spare file, not another role's).
    func isLaunchFile(_ file: URL) -> Bool

    /// The contents of `file`. Throws ``MetricsLaunchFoldError/unreadable(_:)`` for a file whose header or
    /// buckets do not decode (a launch killed while the file was being made).
    func read(_ file: URL) throws(MetricsLaunchFoldError) -> Contents
}

/// Why a launch file could not be folded.
public enum MetricsLaunchFoldError: Error, Sendable, Equatable {
    /// The folder of launch files could not be listed.
    case unlisted(URL)
    /// The file's header or buckets do not decode.
    case unreadable(URL)
    /// The file could not be deleted after its section was uploaded.
    case undeleted(URL)
}
