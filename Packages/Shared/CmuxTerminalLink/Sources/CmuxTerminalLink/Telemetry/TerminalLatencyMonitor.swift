/// Measures input-to-echo round trips and frame age (c1-terminal-rpc.md
/// section 8). A value fed by the source in event order; times are offsets
/// on the source's `LinkClock`.
public struct TerminalLatencyMonitor: Sendable {
    public static let sampleCapacity = 64
    public static let pendingCapacity = 32

    private struct PendingInput: Sendable {
        var hostOffset: UInt64
        var sentAt: Duration
    }

    private var pendingInputs: [PendingInput] = []
    private var samples: [Duration] = []
    public private(set) var report = TerminalLatencyReport()

    public init() {}

    /// Input left for the host while the phone held `hostOffset`.
    public mutating func inputSent(hostOffset: UInt64, at now: Duration) {
        if pendingInputs.count == Self.pendingCapacity { pendingInputs.removeFirst() }
        pendingInputs.append(PendingInput(hostOffset: hostOffset, sentAt: now))
    }

    /// A host `bytes` frame ending at `offset` arrived. Every input sent
    /// before the host passed `offset` closes one sample.
    public mutating func output(endingAt offset: UInt64, at now: Duration) {
        var answered = 0
        for input in pendingInputs where offset > input.hostOffset {
            record(now - input.sentAt)
            answered += 1
        }
        if answered > 0 { pendingInputs.removeFirst(answered) }
    }

    /// The renderer took a frame that waited `wait` in the phone's queue.
    public mutating func frameDelivered(waited wait: Duration) {
        report.frameAge = wait + (report.linkRTT ?? .zero) / 2
    }

    public mutating func linkRTT(_ rtt: Duration?) {
        report.linkRTT = rtt
    }

    /// The echo RTT the predictor uses: the median when measured, else the link's.
    public var effectiveRTT: Duration? { report.echoP50 ?? report.linkRTT }

    /// A READY replaced the screen: inputs waiting for an echo are moot.
    public mutating func keyframe() {
        report.keyframes += 1
        pendingInputs.removeAll()
    }

    public mutating func phoneOverflow() { report.phoneOverflows += 1 }
    public mutating func reattached() {
        report.reattaches += 1
        pendingInputs.removeAll()
    }
    public mutating func predictionShown() { report.predictionsShown += 1 }
    public mutating func predictionConfirmed() { report.predictionsConfirmed += 1 }
    public mutating func predictionRolledBack() { report.predictionRollbacks += 1 }

    private mutating func record(_ sample: Duration) {
        if samples.count == Self.sampleCapacity { samples.removeFirst() }
        samples.append(sample)
        let sorted = samples.sorted()
        report.echoLast = sample
        report.echoSamples = samples.count
        report.echoP50 = sorted[(sorted.count - 1) / 2]
        report.echoP95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
    }
}
