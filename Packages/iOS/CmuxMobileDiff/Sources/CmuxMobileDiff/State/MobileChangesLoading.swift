public import CmuxMobileRPC

/// Main-actor data source required by the native changes screen.
@MainActor
public protocol MobileChangesLoading: AnyObject {
    /// Fetches the current changed-file summary.
    /// - Parameters:
    ///   - baseSpec: Requested Git comparison base.
    ///   - ignoreWhitespace: Whether whitespace-only changes are ignored.
    /// - Returns: Aggregate counts and changed-file metadata.
    /// - Throws: A transport or host RPC failure.
    func summary(baseSpec: MobileChangesBaseSpec, ignoreWhitespace: Bool) async throws -> MobileChangesSummaryResponse
    /// Fetches one cursor-paged file diff.
    /// - Parameters:
    ///   - path: New-side repository-relative path.
    ///   - oldPath: Old-side path for a copy or rename.
    ///   - cursor: Opaque next-page cursor.
    ///   - ignoreWhitespace: Whether whitespace-only changes are ignored.
    ///   - baseSpec: Requested Git comparison base.
    /// - Returns: One page of unified hunks.
    /// - Throws: A transport or host RPC failure.
    func fileDiff(
        path: String,
        oldPath: String?,
        cursor: String?,
        ignoreWhitespace: Bool,
        baseSpec: MobileChangesBaseSpec
    ) async throws -> MobileChangesFileResponse
    /// Fetches an inclusive new-side context interval.
    /// - Parameters:
    ///   - path: Repository-relative path.
    ///   - start: First one-based line, inclusive.
    ///   - end: Last one-based line, inclusive.
    ///   - baseSpec: Requested Git comparison base.
    /// - Returns: Source rows in file order.
    /// - Throws: A transport or host RPC failure.
    func contextLines(
        path: String,
        start: Int,
        end: Int,
        baseSpec: MobileChangesBaseSpec
    ) async throws -> MobileChangesContextResponse
}
