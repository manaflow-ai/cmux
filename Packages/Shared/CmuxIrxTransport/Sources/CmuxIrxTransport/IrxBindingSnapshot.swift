public import Foundation

/// Persisted registration receipt for the irx acceptor tuple.
public struct IrxBindingSnapshot: Codable, Equatable, Sendable {
    /// The broker-issued binding identifier.
    public var bindingID: String
    /// The account-scoped device identifier associated with the binding.
    public var deviceID: String
    /// The build/instance tag that owns the binding.
    public var tag: String
    /// Canonical hex identity of the bound irx endpoint.
    public var endpointIDHex: String
    /// Identity generation used when the binding was registered.
    public var identityGeneration: Int
    /// Time at which the broker accepted this registration.
    public var registeredAt: Date

    /// Creates a persisted registration receipt.
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
