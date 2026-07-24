#if DEBUG
extension RemoteTmuxControlConnection {
    func installStdinWriterForTesting(_ writer: RemoteTmuxControlPipeWriter) {
        stdinWriter = writer
    }

    func handleMessageForTesting(_ message: RemoteTmuxControlMessage) {
        handle(message)
    }

    var pendingCommandKindsForTesting: [RemoteTmuxControlCommandKind] {
        pendingCommands
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
