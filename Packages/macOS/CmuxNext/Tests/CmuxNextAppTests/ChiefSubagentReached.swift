/// Identifies which Chief pane host a handshake reached.
struct ChiefSubagentReached: Error {
    let host: String
}
