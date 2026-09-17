internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation
internal import OSLog

private let explicitTerminalInputLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// Whether the Mac that owns `workspaceID` currently has an RPC channel able to accept terminal input.
    ///
    /// This check does not change the selected Mac, workspace, terminal, or navigation state.
    ///
    /// - Parameter workspaceID: The current UI row identifier for the target workspace.
    /// - Returns: `true` when the workspace exists and its owning Mac has a live RPC client.
    public func canSendTerminalInput(to workspaceID: MobileWorkspacePreview.ID) -> Bool {
        guard workspaces.contains(where: { $0.id == workspaceID }) else { return false }
        return workspaceMutationTarget(for: workspaceID).client != nil
    }

    /// Sends text to an explicit workspace and terminal without changing UI selection or navigation.
    ///
    /// The workspace row selects the owning Mac's live RPC client, including a connected secondary Mac
    /// in the aggregated workspace list, while the Mac-local workspace identifier is sent on the wire.
    ///
    /// - Parameters:
    ///   - text: The exact terminal input bytes represented as text.
    ///   - workspaceID: The current UI row identifier for the target workspace.
    ///   - terminalID: The terminal that must still belong to `workspaceID`.
    /// - Returns: `true` after the owning Mac acknowledges the input; otherwise `false`.
    @discardableResult
    public func sendTerminalInput(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async -> Bool {
        guard !text.isEmpty,
              workspace(workspaceID, containsSurfaceID: terminalID.rawValue) else {
            return false
        }
        let target = workspaceMutationTarget(for: workspaceID)
        guard let client = target.client else { return false }

        do {
            _ = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "terminal.input",
                    params: [
                        "workspace_id": remoteWorkspaceID(for: workspaceID).rawValue,
                        "surface_id": terminalID.rawValue,
                        "text": text,
                        "client_id": clientID,
                    ]
                )
            )
            return true
        } catch {
            explicitTerminalInputLog.error(
                "explicit terminal input failed workspace=\(workspaceID.rawValue, privacy: .private) surface=\(terminalID.rawValue, privacy: .private) error=\(String(describing: error), privacy: .private)"
            )
            return false
        }
    }
}
