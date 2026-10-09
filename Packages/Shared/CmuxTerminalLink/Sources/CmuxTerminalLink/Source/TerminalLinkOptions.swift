/// Tuning of one `LinkTerminalByteSource` (c1-terminal-rpc.md).
public struct TerminalLinkOptions: Hashable, Sendable {
    /// Credit granted to the host (`terminal.viewerBacklogBytes`,
    /// ghostty-next section 2): its per-viewer backlog bound.
    public var window: Int
    /// Frame bytes the phone queues for the renderer before it drops them
    /// and asks for a READY.
    public var queueBudget: Int
    /// Link send budget of the phone's input direction.
    public var inputBudget: Int
    /// GHOSTSNP versions the renderer restores (A2's surface version).
    public var snapshotVersions: [Int]
    /// How long the source waits for the READY it asked for before reattaching.
    public var readyTimeout: Duration
    /// Reattaches in a row without a READY before the source gives up.
    public var maxReattaches: Int
    public var prediction: TerminalPredictionOptions

    public init(window: Int = 256 * 1024, queueBudget: Int = 256 * 1024, inputBudget: Int = 64 * 1024, snapshotVersions: [Int] = [1],
                readyTimeout: Duration = .seconds(10), maxReattaches: Int = 3,
                prediction: TerminalPredictionOptions = TerminalPredictionOptions()) {
        self.window = max(4 * 1024, window)
        self.queueBudget = max(4 * 1024, queueBudget)
        self.inputBudget = max(1024, inputBudget)
        self.snapshotVersions = snapshotVersions
        self.readyTimeout = readyTimeout
        self.maxReattaches = max(1, maxReattaches)
        self.prediction = prediction
    }
}
