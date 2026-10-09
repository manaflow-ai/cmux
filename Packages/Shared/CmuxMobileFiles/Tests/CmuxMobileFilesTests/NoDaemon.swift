import CmuxMobileHost

/// A daemon with an empty tree; the files family does not touch it.
struct NoDaemon: MobileDaemon {
    func workspaceState() async throws -> MobileWorkspaceState {
        MobileWorkspaceState(host: FilesWorld.hostID, workspaces: [])
    }

    func workspaceChanges() async -> AsyncStream<Void> {
        AsyncStream { _ in }
    }

    func perform(_ op: MobileDaemonOp, context: MobileOpContext) async throws -> MobileDaemonOpResult {
        throw MobileDaemonError(code: "proto.unsupported", message: "no ops")
    }

    func attachTerminal(_ request: MobileTerminalAttachRequest) async throws -> any MobileTerminalAttachment {
        throw MobileDaemonError(code: "terminal.not_found", message: "no terminals")
    }
}
