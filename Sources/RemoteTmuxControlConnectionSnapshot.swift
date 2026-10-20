struct RemoteTmuxControlConnectionSnapshot: Sendable {
    let started: Bool
    let enterReceived: Bool
    let exited: Bool
    let sessionId: Int?
    let windowCount: Int
    let windowIDs: [Int]
    let paneOutputByteCounts: [Int: Int]
    let totalOutputBytes: Int
    let recentEvents: [String]
}
