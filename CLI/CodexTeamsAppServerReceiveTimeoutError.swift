struct CodexTeamsAppServerReceiveTimeoutError: Error, CustomStringConvertible {
    var description: String {
        "Timed out waiting for Codex app-server response"
    }
}
