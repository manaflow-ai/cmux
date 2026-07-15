public import CmuxMobileRPC
internal import Foundation

/// Performs read-only workspace-diff RPCs over an existing authenticated Mac connection.
///
/// Instances borrow the shell's persistent client. They never disconnect or replace it;
/// ``MobileShellComposite`` remains the sole owner of connection lifecycle.
public actor MobileDiffsService {
    private let client: MobileCoreRPCClient

    /// Creates a service that borrows an already-connected RPC client.
    /// - Parameter client: The shell-owned authenticated client.
    init(client: MobileCoreRPCClient) {
        self.client = client
    }

    /// Fetches changed-file metadata and aggregate line counts.
    /// - Parameters:
    ///   - workspaceRef: The workspace handle or identifier to inspect.
    ///   - baseSpec: The baseline selection for the comparison.
    ///   - ignoreWhitespace: Whether Git should ignore whitespace changes.
    /// - Returns: The decoded workspace-diff summary.
    /// - Throws: ``MobileDiffsServiceError`` for structured domain failures, or a transport error.
    public func summary(
        workspaceRef: String,
        baseSpec: MobileDiffBaseSpec,
        ignoreWhitespace: Bool = false
    ) async throws -> MobileDiffSummaryResponse {
        try await send(
            method: "mobile.workspace.diffs.summary",
            params: requestParams(
                workspaceRef: workspaceRef,
                baseSpec: baseSpec,
                ignoreWhitespace: ignoreWhitespace
            )
        )
    }

    /// Fetches one cursor page of parsed hunks for a changed file.
    /// - Parameters:
    ///   - workspaceRef: The workspace handle or identifier to inspect.
    ///   - path: The new-side repository-relative path.
    ///   - oldPath: The old-side path for a rename or copy.
    ///   - baseSpec: The baseline selection for the comparison.
    ///   - ignoreWhitespace: Whether Git should ignore whitespace changes.
    ///   - cursor: The host-provided row cursor, or `nil` for the first page.
    ///   - force: Whether to load a textual diff that exceeded the large-file gate.
    /// - Returns: The decoded cursor-paged file response.
    /// - Throws: ``MobileDiffsServiceError`` for structured domain failures, or a transport error.
    public func fileHunks(
        workspaceRef: String,
        path: String,
        oldPath: String? = nil,
        baseSpec: MobileDiffBaseSpec,
        ignoreWhitespace: Bool = false,
        cursor: Int? = nil,
        force: Bool = false
    ) async throws -> MobileDiffFileResponse {
        var params = requestParams(
            workspaceRef: workspaceRef,
            baseSpec: baseSpec,
            ignoreWhitespace: ignoreWhitespace
        )
        params["path"] = path
        if let oldPath {
            params["oldPath"] = oldPath
        }
        if let cursor {
            params["cursor"] = cursor
        }
        params["force"] = force
        return try await send(method: "mobile.workspace.diffs.file", params: params)
    }

    /// Fetches new-side source rows for an expanded context range.
    /// - Parameters:
    ///   - workspaceRef: The workspace handle or identifier to inspect.
    ///   - path: The new-side repository-relative path.
    ///   - startLine: The first one-based new-side line to return.
    ///   - endLine: The last one-based new-side line to return.
    ///   - baseSpec: The baseline selection for the comparison.
    ///   - ignoreWhitespace: Whether Git should ignore whitespace changes.
    /// - Returns: The decoded new-side source rows.
    /// - Throws: ``MobileDiffsServiceError`` for structured domain failures, or a transport error.
    public func contextRows(
        workspaceRef: String,
        path: String,
        startLine: Int,
        endLine: Int,
        baseSpec: MobileDiffBaseSpec,
        ignoreWhitespace: Bool = false
    ) async throws -> MobileDiffContextResponse {
        var params = requestParams(
            workspaceRef: workspaceRef,
            baseSpec: baseSpec,
            ignoreWhitespace: ignoreWhitespace
        )
        params["path"] = path
        params["startLine"] = startLine
        params["endLine"] = endLine
        return try await send(method: "mobile.workspace.diffs.context", params: params)
    }

    private func requestParams(
        workspaceRef: String,
        baseSpec: MobileDiffBaseSpec,
        ignoreWhitespace: Bool
    ) -> [String: Any] {
        var encodedBase: [String: Any] = ["kind": baseSpec.kind.rawValue]
        if let value = baseSpec.value {
            encodedBase["value"] = value
        }
        return [
            "workspaceRef": workspaceRef,
            "baseSpec": encodedBase,
            "ignoreWhitespace": ignoreWhitespace,
        ]
    }

    private func send<Response: Decodable & Sendable>(
        method: String,
        params: [String: Any]
    ) async throws -> Response {
        do {
            let request = try MobileCoreRPCClient.requestData(method: method, params: params)
            let response = try await client.sendRequest(request)
            return try JSONDecoder().decode(Response.self, from: response)
        } catch let error as MobileShellConnectionError {
            guard case let .rpcError(code, _) = error else { throw error }
            switch code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "workspace_not_found":
                throw MobileDiffsServiceError.unknownWorkspace
            case "not_git_repository":
                throw MobileDiffsServiceError.notGitRepository
            case "baseline_unavailable":
                throw MobileDiffsServiceError.baselineMissing
            default:
                throw error
            }
        }
    }
}
