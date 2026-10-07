public import CmuxMobileHost
public import CmuxNextDaemon
public import Foundation

/// `MobileTaskWorkspaces` over the daemon's workspace store: `create-workspace`
/// (no argv, cwd or environment), the workspace's directory (its first local
/// terminal's presented directory, else its agent-home folder
/// `~/Library/Application Support/cmux/agent-home/<ws id>`, the folder the
/// Mac's own agent tabs use for a workspace without one), and
/// `new-conversation-tab` for an agent chat tab on the session.
public struct DaemonTaskWorkspaces: MobileTaskWorkspaces {
    private let daemon: DaemonMobileDaemon
    private let agentHost: String
    private let agentHostName: String?
    private let agentHomes: URL

    /// - Parameters:
    ///   - agentHost: this Mac's stable install id, the host agent tabs record (`AgentSessionRef.host`).
    ///   - agentHomes: the agent-home base folder.
    public init(daemon: DaemonMobileDaemon, agentHost: String, agentHostName: String?, agentHomes: URL) {
        self.daemon = daemon
        self.agentHost = agentHost
        self.agentHostName = agentHostName
        self.agentHomes = agentHomes
    }

    public func createWorkspace(idempotencyKey: String) async throws -> String {
        let result = try await daemon.connection.createWorkspace(name: nil)
        let tree = try await daemon.currentTree()
        guard let id = tree.workspaces.first(where: { $0.id == result.workspace || $0.key == result.key })?.resourceID?.rawValue else {
            throw MobileDaemonError(code: "owner.unreachable", message: "the new workspace has no id yet", retryable: true)
        }
        return id
    }

    public func directory(of workspace: String) async throws -> String {
        let tree = try await daemon.currentTree()
        if let root = MobileWorkspaceRoots.roots(in: tree).first(where: { $0.id == workspace }) { return root.url.path }
        guard Self.isSafeID(workspace) else {
            throw MobileDaemonError(code: "workspace.not_found", message: "\(workspace) names no folder")
        }
        let folder = agentHomes.appendingPathComponent(workspace, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder.path
    }

    public func openAgentTab(workspace: String, session: String, harness: String, idempotencyKey: String) async throws -> String {
        let tree = try await daemon.currentTree()
        guard let handle = tree.workspaces.first(where: { $0.resourceID?.rawValue == workspace })?.id else {
            throw MobileDaemonError(code: "workspace.not_found", message: "\(workspace) is not on this Mac")
        }
        let record = AgentSessionRef(host: agentHost, hostName: agentHostName, session: session, harness: harness)
        let response = try await daemon.connection.request(NewConversationTabRequest(
            agentSession: record, workspace: handle, origin: "cmux-next-mobile-task", mutationID: idempotencyKey))
        guard let tab = response.tabResourceID?.rawValue else {
            throw MobileDaemonError(code: "owner.unreachable", message: "the agent tab has no id", retryable: true)
        }
        return tab
    }

    /// 1 to 128 characters of `[A-Za-z0-9_-]` (the agent-home folder rule).
    static func isSafeID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F
        }
    }
}
