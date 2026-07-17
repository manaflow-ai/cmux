public import Foundation

/// The private frame endpoint handed to exactly one renderer worker.
public struct TerminalRenderFrameEndpoint: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case serviceName
        case capability
    }

    /// The random per-receiver bootstrap name used to acquire the Mach send right.
    public let serviceName: String

    /// The random per-worker capability checked on every frame message.
    public let capability: Data

    /// Creates and validates a frame endpoint.
    ///
    /// - Parameters:
    ///   - serviceName: A non-empty bootstrap name with no embedded NUL byte.
    ///   - capability: Exactly ``TerminalRenderFrameProtocol/capabilityLength`` random bytes.
    /// - Throws: ``TerminalRenderFrameProtocolError`` when either value is malformed.
    public init(serviceName: String, capability: Data) throws {
        let serviceNameBytes = serviceName.utf8
        guard !serviceNameBytes.isEmpty,
              serviceNameBytes.count <= TerminalRenderFrameProtocol.maximumServiceNameLength,
              !serviceNameBytes.contains(0) else {
            throw TerminalRenderFrameProtocolError.invalidServiceName
        }
        guard capability.count == TerminalRenderFrameProtocol.capabilityLength else {
            throw TerminalRenderFrameProtocolError.invalidCapabilityLength
        }
        self.serviceName = serviceName
        self.capability = capability
    }

    /// Decodes an endpoint through the same security validation as ``init(serviceName:capability:)``.
    ///
    /// - Parameter decoder: Decoder containing a service name and fixed-length capability.
    /// - Throws: ``TerminalRenderFrameProtocolError`` when decoded values are malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            serviceName: container.decode(String.self, forKey: .serviceName),
            capability: container.decode(Data.self, forKey: .capability)
        )
    }

    /// Encodes the validated service name and capability for worker bootstrap.
    ///
    /// - Parameter encoder: Encoder receiving the validated endpoint fields.
    /// - Throws: Any error produced by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serviceName, forKey: .serviceName)
        try container.encode(capability, forKey: .capability)
    }
}
