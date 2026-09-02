public import Foundation

/// Encodes the pure protocol and retry decisions for a manual-IO relay.
public struct TuiManualIOPumpPolicy: Sendable {
    /// Describes why one relay process ended.
    public enum RelayExit: Equatable, Sendable {
        /// The daemon terminal ended and must not be respawned.
        case terminalEnded
        /// The daemon connection was lost and can be reattached.
        case daemonLost
        /// The parent closed stdin during teardown.
        case parentClosed
        /// The process failed without a recoverable protocol reason.
        case failure
    }

    /// Describes the state transition after a relay exit.
    public enum NextAction: Equatable, Sendable {
        /// Keep the pane in its terminal-ended state.
        case end
        /// Schedule another relay attach.
        case retry
        /// Leave the current state unchanged.
        case ignore
    }

    /// The maximum unexplained failure streak before automatic retry stops.
    public let maxConsecutiveUnexplainedFailures: Int
    /// The minimum interval between geometry claims from one input channel.
    public let claimInterval: TimeInterval
    /// The JSON line that reclaims terminal geometry for this pane.
    public let claimGeometryLine: Data
    /// The reset sequence emitted before replaying a reconnect snapshot.
    public let resyncReset: Data

    /// Creates the default cloud relay policy.
    public init(
        maxConsecutiveUnexplainedFailures: Int = 5,
        claimInterval: TimeInterval = 5
    ) {
        self.maxConsecutiveUnexplainedFailures = maxConsecutiveUnexplainedFailures
        self.claimInterval = claimInterval
        claimGeometryLine = Data(#"{"claim":{"geometry":true}}"#.utf8 + [0x0A])
        resyncReset = Data([0x1B, 0x63, 0x1B, 0x5B, 0x33, 0x4A])
    }

    /// Classifies a relay exit from its status and final JSON stderr line.
    public func relayExit(status: Int32, stderrText: String?) -> RelayExit {
        let reason = stderrText?
            .split(separator: "\n")
            .reversed()
            .compactMap { line -> String? in
                guard let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let exit = object["exit"] as? [String: Any]
                else { return nil }
                return exit["reason"] as? String
            }
            .first
        switch (status, reason) {
        case (0, "terminal-ended"): return .terminalEnded
        case (0, "parent-closed"): return .parentClosed
        case (2, "daemon-lost"): return .daemonLost
        default: return .failure
        }
    }

    /// Selects the next pump action for an exit classification.
    public func nextAction(after exit: RelayExit) -> NextAction {
        switch exit {
        case .terminalEnded: return .end
        case .daemonLost, .failure: return .retry
        case .parentClosed: return .ignore
        }
    }

    /// Returns whether buffered output is valid for the given pump state.
    public func acceptsRelayOutput(state: TuiManualIOPumpState) -> Bool {
        switch state {
        case .connecting, .live, .reconnecting: return true
        case .ended, .failed: return false
        }
    }

    /// Returns the bounded reconnect delay for a one-based attempt number.
    public func retryDelay(attempt: Int) -> Duration {
        let schedule: [Duration] = [
            .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16),
        ]
        guard attempt >= 1 else { return schedule[0] }
        guard attempt <= schedule.count else { return .seconds(30) }
        return schedule[attempt - 1]
    }

    /// Encodes raw terminal input as one relay stdin line.
    public func inputLine(bytes: Data) -> Data {
        var line = Data(#"{"input":""#.utf8)
        line.append(Data(bytes.base64EncodedString().utf8))
        line.append(Data(#""}"#.utf8))
        line.append(0x0A)
        return line
    }

    /// Encodes a daemon-side resize request.
    public func resizeLine(cols: Int, rows: Int) -> Data {
        Data(#"{"resize":{"cols":\#(max(1, cols)),"rows":\#(max(1, rows))}}"#.utf8 + [0x0A])
    }

    /// Builds direct process arguments for one relay target.
    public func relayArguments(
        target: TuiManualIORelayTarget,
        terminalID: String,
        cols: Int,
        rows: Int
    ) -> [String] {
        let scoped: [String]
        switch target {
        case .session(let name):
            scoped = ["attach", "--session", name]
        case .socket(let path):
            scoped = ["--socket", path, "attach"]
        }
        return scoped + [
            "--terminal", terminalID,
            "--pipe-io",
            "--cols", String(max(1, cols)),
            "--rows", String(max(1, rows)),
        ]
    }
}
