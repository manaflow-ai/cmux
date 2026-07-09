public struct RemoteTmuxControlConnectionSnapshot: Sendable {
    public let started: Bool
    public let enterReceived: Bool
    public let exited: Bool
    public let sessionId: Int?
    public let windowCount: Int
    public let windowIDs: [Int]
    public let paneOutputByteCounts: [Int: Int]
    public let totalOutputBytes: Int
    public let recentEvents: [String]

    public init(
        started: Bool,
        enterReceived: Bool,
        exited: Bool,
        sessionId: Int?,
        windowCount: Int,
        windowIDs: [Int],
        paneOutputByteCounts: [Int: Int],
        totalOutputBytes: Int,
        recentEvents: [String]
    ) {
        self.started = started
        self.enterReceived = enterReceived
        self.exited = exited
        self.sessionId = sessionId
        self.windowCount = windowCount
        self.windowIDs = windowIDs
        self.paneOutputByteCounts = paneOutputByteCounts
        self.totalOutputBytes = totalOutputBytes
        self.recentEvents = recentEvents
    }
}
