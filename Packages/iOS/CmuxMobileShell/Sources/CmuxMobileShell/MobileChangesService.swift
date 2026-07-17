public import CmuxMobileRPC
internal import Foundation

/// Fetches native workspace changes over the shell's live, authenticated RPC client.
@MainActor
public final class MobileChangesService {
    private let client: MobileCoreRPCClient
    private let workspaceID: String

    /// Creates a workspace-bound service over the composite's authoritative client.
    /// - Parameters:
    ///   - client: The connected, multiplexed RPC client owned by ``MobileShellComposite``.
    ///   - workspaceID: The Mac-local workspace identifier added to every request.
    init(client: MobileCoreRPCClient, workspaceID: String) {
        self.client = client
        self.workspaceID = workspaceID
    }

    /// Fetches the changed-file summary for the bound workspace.
    /// - Parameters:
    ///   - baseSpec: The baseline used for the comparison.
    ///   - ignoreWhitespace: Whether Git should ignore whitespace changes.
    /// - Returns: Aggregate counts and changed-file summaries.
    /// - Throws: A transport, RPC, cancellation, encoding, or decoding error.
    public func summary(
        baseSpec: MobileChangesBaseSpec,
        ignoreWhitespace: Bool
    ) async throws -> MobileChangesSummaryResponse {
        try await call(
            method: "mobile.workspace.changes.summary",
            request: MobileChangesSummaryRequest(
                workspaceID: workspaceID,
                baseSpec: baseSpec,
                ignoreWhitespace: ignoreWhitespace
            ),
            response: MobileChangesSummaryResponse.self
        )
    }

    /// Fetches one cursor-paged file diff for the bound workspace.
    /// - Parameters:
    ///   - path: The new-side repository-relative path.
    ///   - oldPath: The old-side path for a rename or copy, when present.
    ///   - cursor: The previous response's opaque cursor, or `nil` for the first page.
    ///   - ignoreWhitespace: Whether Git should ignore whitespace changes.
    ///   - baseSpec: The baseline used for the comparison.
    /// - Returns: One page of unified-diff hunks.
    /// - Throws: A transport, RPC, cancellation, encoding, or decoding error.
    public func fileDiff(
        path: String,
        oldPath: String?,
        cursor: String?,
        ignoreWhitespace: Bool,
        baseSpec: MobileChangesBaseSpec
    ) async throws -> MobileChangesFileResponse {
        try await call(
            method: "mobile.workspace.changes.file",
            request: MobileChangesFileRequest(
                workspaceID: workspaceID,
                path: path,
                oldPath: oldPath,
                cursor: cursor,
                ignoreWhitespace: ignoreWhitespace,
                baseSpec: baseSpec
            ),
            response: MobileChangesFileResponse.self
        )
    }

    /// Fetches an inclusive range of new-side context lines for the bound workspace.
    /// - Parameters:
    ///   - path: The repository-relative path.
    ///   - start: The first one-based line to fetch, inclusive.
    ///   - end: The last one-based line to fetch, inclusive.
    ///   - baseSpec: The baseline used to resolve the workspace changes context.
    /// - Returns: The requested lines in file order.
    /// - Throws: A transport, RPC, cancellation, encoding, or decoding error.
    public func contextLines(
        path: String,
        start: Int,
        end: Int,
        baseSpec: MobileChangesBaseSpec
    ) async throws -> MobileChangesContextResponse {
        try await call(
            method: "mobile.workspace.changes.context",
            request: MobileChangesContextRequest(
                workspaceID: workspaceID,
                path: path,
                startLine: start,
                endLine: end,
                baseSpec: baseSpec
            ),
            response: MobileChangesContextResponse.self
        )
    }

    private func call<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        request: Request,
        response: Response.Type
    ) async throws -> Response {
        try Task.checkCancellation()
        let encoded = try JSONEncoder().encode(request)
        guard let params = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw EncodingError.invalidValue(
                request,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Changes request must encode as a JSON object"
                )
            )
        }
        let requestData = try MobileCoreRPCClient.requestData(method: method, params: params)
        let result: Data
        do {
            result = try await client.sendRequest(requestData)
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            throw error
        }
        guard !Task.isCancelled else { throw CancellationError() }
        return try JSONDecoder().decode(response, from: result)
    }
}
