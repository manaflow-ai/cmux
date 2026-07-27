/// The versioned wire contract for compact Simulator UI snapshots.
public let simulatorUIAutomationProtocol = "rs/1"

/// The lifetime of element references emitted by one Simulator UI snapshot.
public let simulatorUIAutomationSnapshotLifetimeMilliseconds: Int64 = 60_000

/// The largest sampled gesture accepted by semantic Simulator automation.
public let simulatorUIAutomationMaximumGestureEventCount = 1_001

/// The largest candidate list included in one recoverable automation error.
public let simulatorUIAutomationMaximumCandidateCount = 64

/// A versioned compact snapshot whose refs are scoped to one Simulator pane.
public struct SimulatorUIAutomationSnapshot: Codable, Equatable, Sendable {
    /// The payload discriminator.
    public let type: String
    /// The runtime snapshot protocol version.
    public let `protocol`: String
    /// The selected CoreSimulator device identifier.
    public let simulatorID: String
    /// A deterministic hash of the visible semantic state.
    public let screenHash: String
    /// The pane-local monotonically increasing snapshot sequence.
    public let sequence: UInt64
    /// The capture time in Unix epoch milliseconds.
    public let capturedAtMilliseconds: Int64
    /// The element-reference expiry time in Unix epoch milliseconds.
    public let expiresAtMilliseconds: Int64
    /// The compact semantic elements.
    public let elements: [SimulatorUIAutomationElement]
    /// Suggested actions derived from the elements.
    public let actions: [SimulatorUIAutomationActionHint]
    /// Whether the native accessibility tree reached its bounded element limit.
    public let isTruncated: Bool

    /// Creates one versioned runtime snapshot.
    ///
    /// - Parameters:
    ///   - simulatorID: The selected CoreSimulator device identifier.
    ///   - screenHash: The deterministic semantic-state hash.
    ///   - sequence: The pane-local sequence.
    ///   - capturedAtMilliseconds: The capture time.
    ///   - expiresAtMilliseconds: The element-reference expiry time.
    ///   - elements: The compact semantic elements.
    ///   - actions: Suggested semantic actions.
    ///   - isTruncated: Whether native capture reached its element limit.
    public init(
        simulatorID: String,
        screenHash: String,
        sequence: UInt64,
        capturedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        elements: [SimulatorUIAutomationElement],
        actions: [SimulatorUIAutomationActionHint],
        isTruncated: Bool
    ) {
        self.type = "runtime-snapshot"
        self.protocol = simulatorUIAutomationProtocol
        self.simulatorID = simulatorID
        self.screenHash = screenHash
        self.sequence = sequence
        self.capturedAtMilliseconds = capturedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.elements = elements
        self.actions = actions
        self.isTruncated = isTruncated
    }
}
