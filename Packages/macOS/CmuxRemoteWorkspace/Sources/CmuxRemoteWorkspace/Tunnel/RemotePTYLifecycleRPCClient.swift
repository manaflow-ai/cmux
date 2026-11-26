internal import CmuxRemoteDaemon
internal import Foundation

/// Testable PTY-only seam used by the tunnel's lifecycle and bridge operations.
protocol RemotePTYLifecycleRPCClient: RemotePTYBridgeRPCClient {
    func listPTY() throws -> [[String: Any]]
    func closePTY(sessionID: String, timeout: TimeInterval) throws
    func resizePTY(sessionID: String, attachmentID: String, attachmentToken: String, cols: Int, rows: Int) throws
    func detachPTYChecked(sessionID: String, attachmentID: String, attachmentToken: String) throws
}
