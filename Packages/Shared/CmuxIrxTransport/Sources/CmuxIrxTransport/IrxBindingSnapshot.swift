public import Foundation

/// Persisted registration receipt for the irx acceptor tuple.
public struct IrxBindingSnapshot: Codable, Equatable, Sendable {
    public var bindingID: String
    public var deviceID: String
    public var tag: String
    public var endpointIDHex: String
    public var identityGeneration: Int
    public var registeredAt: Date

    public init(
        bindingID: String,
        deviceID: String,
        tag: String,
        endpointIDHex: String,
        identityGeneration: Int,
        registeredAt: Date
    ) {
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.tag = tag
        self.endpointIDHex = endpointIDHex
        self.identityGeneration = identityGeneration
        self.registeredAt = registeredAt
    }
}
