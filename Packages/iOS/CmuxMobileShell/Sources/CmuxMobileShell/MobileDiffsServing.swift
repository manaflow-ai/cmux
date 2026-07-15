public import CmuxMobileRPC

/// Read-only workspace-diff operations consumed by the native diff screen.
public protocol MobileDiffsServing: Sendable {
    /// Fetches changed-file metadata and aggregate counts.
    func summary(
        workspaceRef: String,
        baseSpec: MobileDiffBaseSpec,
        ignoreWhitespace: Bool
    ) async throws -> MobileDiffSummaryResponse

    /// Fetches one cursor page of parsed hunks for a changed file.
    func fileHunks(
        workspaceRef: String,
        path: String,
        oldPath: String?,
        baseSpec: MobileDiffBaseSpec,
        ignoreWhitespace: Bool,
        cursor: Int?,
        force: Bool
    ) async throws -> MobileDiffFileResponse

    /// Fetches new-side source rows for an expanded context range.
    func contextRows(
        workspaceRef: String,
        path: String,
        startLine: Int,
        endLine: Int,
        baseSpec: MobileDiffBaseSpec,
        ignoreWhitespace: Bool
    ) async throws -> MobileDiffContextResponse
}
