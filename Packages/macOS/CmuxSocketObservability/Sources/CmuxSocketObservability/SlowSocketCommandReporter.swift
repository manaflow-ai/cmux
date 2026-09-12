import Foundation

/// Times CLI socket commands and reports slow observations to a sink.
nonisolated public final class SlowSocketCommandReporter: Sendable {
    /// Commands taking at least this long are logged in release builds.
    public static let slowThresholdMs: Double = 100

    private let sink: SlowSocketCommandSink

    public init(sink: any SlowSocketCommandSink) {
        self.sink = sink
    }

    public static func isSlow(durationMs: Double) -> Bool {
        durationMs >= slowThresholdMs
    }

    public func reportIfSlow(_ observation: SocketCommandObservation) {
        guard Self.isSlow(durationMs: observation.durationMs) else { return }
        sink.recordSlowCommand(observation)
    }
}
