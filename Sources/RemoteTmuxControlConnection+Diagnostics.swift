extension RemoteTmuxControlConnection {
  func record(_ event: String) {
    diagnostics.record(event)
  }

  /// An immutable, `Sendable` snapshot for diagnostics (`remote.tmux.state`).
  func snapshot() -> Snapshot {
    Snapshot(
      started: started,
      enterReceived: enterReceived,
      exited: exited,
      sessionId: sessionId,
      windowCount: windowsByID.count,
      windowIDs: windowOrder,
      paneOutputByteCounts: paneOutputByteCounts,
      totalOutputBytes: totalOutputBytes,
      recentEvents: diagnostics.events
    )
  }

  #if DEBUG
    func installStdinWriterForTesting(_ writer: RemoteTmuxControlPipeWriter) {
      stdinWriter = writer
    }
    func handleMessageForTesting(_ message: RemoteTmuxControlMessage) { handle(message) }
    var pendingCommandKindsForTesting: [RemoteTmuxControlCommandKind] { pendingCommands }
  #endif
}
