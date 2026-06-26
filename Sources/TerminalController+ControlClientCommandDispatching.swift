import CmuxControlSocket

/// Routes the package's per-connection command-dispatch seam
/// (``ControlClientCommandDispatching``) back into the app's live command
/// plumbing. The connection transport pipeline — access control, the password
/// handshake, line framing, and the response write — lives in
/// ``ControlClientConnectionHandler``; the command bodies stay here because
/// they reach into the event bus and the v1/v2 command switch.
///
/// Each witness forwards to the existing app method the legacy
/// `handleClient` loop called inline: `isEventsStreamRequest`,
/// `handleEventsStreamRequest`, `processSocketLine`, and `publishSocketEvents`.
extension TerminalController: ControlClientCommandDispatching {
    nonisolated func handleEventsStream(line: String, socket: Int32) {
        handleEventsStreamRequest(line, socket: socket)
    }

    nonisolated func processCommandLine(
        _ line: String,
        authenticated: Bool
    ) -> ControlClientCommandOutcome {
        let result = processSocketLine(line, authenticated: authenticated)
        return ControlClientCommandOutcome(
            response: result.response,
            authenticated: result.authenticated
        )
    }

    nonisolated func publishCommandEvents(command: String, response: String) {
        publishSocketEvents(command: command, response: response)
    }
}
