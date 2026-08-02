/// The versioned wire contract for compact Simulator UI snapshots.
public let simulatorUIAutomationProtocol = "rs/1"

/// The lifetime of element references emitted by one Simulator UI snapshot.
public let simulatorUIAutomationSnapshotLifetimeMilliseconds: Int64 = 60_000

/// The largest sampled gesture accepted by semantic Simulator automation.
public let simulatorUIAutomationMaximumGestureEventCount = 1_001

/// The largest candidate list included in one recoverable automation error.
public let simulatorUIAutomationMaximumCandidateCount = 64

/// An accessibility field clipped by the native worker's field-size limit.
public enum SimulatorUIAutomationTruncatedField: String, Codable, CaseIterable, Sendable {
    case identifier
    case label
    case value
}

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
    /// Visible accessibility fields clipped by the native worker.
    public let truncatedFields: [SimulatorUIAutomationTruncatedField]

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
    ///   - truncatedFields: Visible native fields clipped during capture.
    public init(
        simulatorID: String,
        screenHash: String,
        sequence: UInt64,
        capturedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        elements: [SimulatorUIAutomationElement],
        actions: [SimulatorUIAutomationActionHint],
        isTruncated: Bool,
        truncatedFields: [SimulatorUIAutomationTruncatedField]
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
        self.truncatedFields = truncatedFields
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case `protocol`
        case simulatorID
        case screenHash
        case sequence
        case capturedAtMilliseconds
        case expiresAtMilliseconds
        case elements
        case actions
        case isTruncated
        case truncatedFields
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        self.protocol = try container.decode(String.self, forKey: .protocol)
        simulatorID = try container.decode(String.self, forKey: .simulatorID)
        screenHash = try container.decode(String.self, forKey: .screenHash)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        capturedAtMilliseconds = try container.decode(
            Int64.self,
            forKey: .capturedAtMilliseconds
        )
        expiresAtMilliseconds = try container.decode(
            Int64.self,
            forKey: .expiresAtMilliseconds
        )
        elements = try container.decode(
            [SimulatorUIAutomationElement].self,
            forKey: .elements
        )
        actions = try container.decode(
            [SimulatorUIAutomationActionHint].self,
            forKey: .actions
        )
        isTruncated = try container.decode(Bool.self, forKey: .isTruncated)
        truncatedFields = try container.decodeIfPresent(
            [SimulatorUIAutomationTruncatedField].self,
            forKey: .truncatedFields
        ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(`protocol`, forKey: .protocol)
        try container.encode(simulatorID, forKey: .simulatorID)
        try container.encode(screenHash, forKey: .screenHash)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(capturedAtMilliseconds, forKey: .capturedAtMilliseconds)
        try container.encode(expiresAtMilliseconds, forKey: .expiresAtMilliseconds)
        try container.encode(elements, forKey: .elements)
        try container.encode(actions, forKey: .actions)
        try container.encode(isTruncated, forKey: .isTruncated)
        if !truncatedFields.isEmpty {
            try container.encode(truncatedFields, forKey: .truncatedFields)
        }
    }
}
