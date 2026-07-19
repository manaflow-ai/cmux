internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation

/// The store-side service surface for the iOS Dispatch composer: catalog,
/// directory search/browse, and the launch request itself.
///
/// The client gate for the feature is the host capability ONLY — attach-ticket
/// scoping is enforced server-side, and workspace-scoped tickets are allowed to
/// dispatch (matching `workspace.create`).
extension MobileShellComposite: DispatchComposerServicing {
    static let agentDispatchCapability = "workspace.dispatch.v1"

    /// Whether the connected Mac supports the Dispatch composer RPCs.
    public var supportsAgentDispatch: Bool {
        supportedHostCapabilities.contains(Self.agentDispatchCapability)
    }

    /// Host name shown on the work-order header.
    public var dispatchHostName: String? { connectedHostName }

    /// Whether a launch attempted right now could reach the Mac.
    public var dispatchIsConnected: Bool { connectionState == .connected }

    /// Stable key for per-Mac dispatch drafts and serials.
    public var dispatchMacKey: String { foregroundMacDeviceID ?? "default" }

    public func dispatchCatalog() async throws -> DispatchCatalog {
        guard let client = remoteClient else { throw DispatchLaunchFailure.notConnected }
        let data = try await client.sendRequest(
            MobileCoreRPCClient.requestData(method: "mobile.dispatch.catalog", params: [:])
        )
        return try DispatchCatalog.decode(data)
    }

    public func dispatchFSList(path: String, includeHidden: Bool) async throws -> DispatchFSList {
        guard let client = remoteClient else { throw DispatchLaunchFailure.notConnected }
        let data = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.dispatch.fs",
                params: ["op": "list", "path": path, "include_hidden": includeHidden]
            )
        )
        return try DispatchFSList.decode(data)
    }

    public func dispatchFSSearch(query: String) async throws -> DispatchFSSearch {
        guard let client = remoteClient else { throw DispatchLaunchFailure.notConnected }
        let data = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.dispatch.fs",
                params: ["op": "search", "query": query]
            )
        )
        return try DispatchFSSearch.decode(data)
    }

    /// Launch an agent workspace from a composed brief.
    ///
    /// On success the Mac's response carries the refreshed workspace list plus
    /// the created workspace id; this applies the list and selects the new
    /// workspace so the shell's existing selection-driven navigation pushes
    /// straight into its live terminal.
    public func dispatchLaunch(
        directory: String,
        agentID: String,
        prompt: String
    ) async -> Result<Void, DispatchLaunchFailure> {
        guard let client = remoteClient else {
            return .failure(.notConnected)
        }
        let generation = connectionGeneration
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "mobile.dispatch.launch",
                    params: [
                        "directory": directory,
                        "agent_id": agentID,
                        "prompt": prompt,
                    ]
                )
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard isCurrentRemoteOperation(client: client, generation: generation), !Task.isCancelled else {
                return .success(())
            }
            applyRemoteWorkspaceList(response, mergeExistingWorkspaces: true)
            if let createdWorkspace = response.createdWorkspaceID.map(MobileWorkspacePreview.ID.init(rawValue:)) {
                setSelectedWorkspaceID(
                    rowWorkspaceID(
                        forRemoteWorkspaceID: createdWorkspace,
                        macDeviceID: foregroundMacDeviceID
                    ) ?? createdWorkspace
                )
                syncSelectedTerminalForWorkspace()
                // The dispatched terminal is freshly created and the agent owns it;
                // opening it must not steal keyboard focus from the user.
                suppressTerminalAutoFocusOnNextAttach(for: selectedTerminalID)
            }
            return .success(())
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return .success(()) }
            if disconnectForAuthorizationFailureIfNeeded(error) {
                return .failure(.authorizationFailed)
            }
            markMacConnectionUnavailableIfNeeded(after: error)
            return .failure(Self.dispatchLaunchFailure(from: error))
        }
    }

    static func dispatchLaunchFailure(from error: any Error) -> DispatchLaunchFailure {
        guard let connectionError = error as? MobileShellConnectionError else {
            return .rejected(message: nil)
        }
        switch connectionError {
        case .connectionClosed:
            return .notConnected
        case .requestTimedOut:
            return .requestTimedOut
        case .attachTicketExpired, .authorizationFailed, .accountMismatch, .insecureManualRoute:
            return .authorizationFailed
        case let .rpcError(code, message):
            let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalizedCode {
            case "agent_not_installed":
                return .agentNotInstalled
            case "directory_not_found":
                return .directoryNotFound
            case "prompt_too_long":
                return .promptTooLong
            case "unavailable":
                return .notConnected
            case "unauthorized", "forbidden", "invalid_token", "token_expired", "expired_token",
                 "auth_required", "account_mismatch":
                return .authorizationFailed
            default:
                return .rejected(message: message)
            }
        case .invalidResponse:
            return .rejected(message: nil)
        }
    }
}
