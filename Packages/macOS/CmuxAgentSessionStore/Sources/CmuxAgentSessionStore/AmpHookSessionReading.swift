public import Foundation

/// Reads validated Amp thread snapshots from a cmux-managed session-history source.
public protocol AmpHookSessionReading: Sendable {
    /// Returns one filtered and ordered page of Amp thread snapshots.
    ///
    /// - Parameters:
    ///   - sourceURL: Location of the cmux-managed Amp hook-session store.
    ///   - query: Case-insensitive text matched against thread id, title, and working directory.
    ///   - workingDirectory: Optional normalized exact-directory filter.
    ///   - offset: Number of matching snapshots to skip.
    ///   - limit: Maximum number of matching snapshots to return.
    /// - Returns: A page sorted by latest activity descending, then thread id.
    /// - Throws: ``AmpHookSessionRepositoryError/unreadableStore`` when an existing store cannot be read.
    func snapshots(
        at sourceURL: URL,
        matching query: String,
        workingDirectory: String?,
        offset: Int,
        limit: Int
    ) async throws -> [AmpHookSessionSnapshot]
}
