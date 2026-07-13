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
}
#endif
