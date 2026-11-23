#if DEBUG
import CmuxRemoteSession

extension RemoteTmuxControlConnection {
    func installStdinWriterForTesting(_ writer: RemoteTmuxControlPipeWriter) {
        stdinWriter = writer
    }

    /// Handles `message` as if the parser had just produced it.
    func handleMessageForTesting(_ message: RemoteTmuxControlMessage) {
        handle(message)
    }

    /// The commands awaiting a reply, oldest first.
    var pendingCommandKindsForTesting: [RemoteTmuxControlCommandKind] {
        Array(pendingCommands)
    }

    func hasPendingSizingSettlementWork(windowId: Int) -> Bool {
        if pendingLayouts[windowId] != nil { return true }
        return pendingCommands.contains { command in
            switch command {
            case .paneRects(let pendingWindowId, _), .perWindowSize(let pendingWindowId):
                return pendingWindowId == windowId
            case .listWindows:
                return true
            default:
                return false
            }
        }
    }
}
#endif
