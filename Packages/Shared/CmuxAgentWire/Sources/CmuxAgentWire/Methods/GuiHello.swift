public import CmuxAgentReplica

/// Parameters sent when negotiating the `gui.v1` protocol.
public struct GuiHelloParams: Codable, Hashable, Sendable {
    /// The oldest protocol version the client supports.
    public let protocolMin: Int
    /// The newest protocol version the client supports.
    public let protocolMax: Int
    /// Open capability strings advertised by the client.
    public let clientCaps: [String]

    private enum CodingKeys: String, CodingKey {
        case protocolMin = "protocol_min"
        case protocolMax = "protocol_max"
        case clientCaps = "client_caps"
    }

    /// Creates hello parameters.
    /// - Parameters:
    ///   - protocolMin: The oldest supported protocol version.
    ///   - protocolMax: The newest supported protocol version.
    ///   - clientCaps: Open client capability strings.
    public init(protocolMin: Int, protocolMax: Int, clientCaps: [String]) {
        self.protocolMin = protocolMin
        self.protocolMax = protocolMax
        self.clientCaps = clientCaps
    }
}

/// Result returned after negotiating the `gui.v1` protocol.
public struct GuiHelloResult: Codable, Hashable, Sendable {
    /// The negotiated protocol version.
    public let `protocol`: Int
    /// Open capability strings advertised by the server.
    public let serverCaps: [String]
    /// The current Mac process epoch.
    public let epoch: ReplicaEpoch
    /// The stable identifier of the serving Mac.
    public let macDeviceID: MacDeviceID
    /// Server epoch milliseconds for display offset calculations only.
    public let serverTimeMS: Int64

    private enum CodingKeys: String, CodingKey {
        case `protocol`
        case serverCaps = "server_caps"
        case epoch
        case macDeviceID = "mac_device_id"
        case serverTimeMS = "server_time_ms"
    }

    /// Creates a hello result.
    /// - Parameters:
    ///   - protocol: The negotiated protocol version.
    ///   - serverCaps: Open server capability strings.
    ///   - epoch: The current Mac process epoch.
    ///   - macDeviceID: The stable serving Mac identifier.
    ///   - serverTimeMS: Epoch milliseconds used only to calculate display offsets.
    public init(
        protocol: Int,
        serverCaps: [String],
        epoch: ReplicaEpoch,
        macDeviceID: MacDeviceID,
        serverTimeMS: Int64
    ) {
        self.protocol = `protocol`
        self.serverCaps = serverCaps
        self.epoch = epoch
        self.macDeviceID = macDeviceID
        self.serverTimeMS = serverTimeMS
    }
}
