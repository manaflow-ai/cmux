internal import Foundation

/// One server-pushed event. The event discriminator stays typed while each
/// capability owns the schema of its remaining fields.
public struct BackendServerEvent: Codable, Equatable, Sendable {
    /// The event discriminator encoded in the `event` wire field.
    public let name: String

    /// The event-specific fields excluding the event discriminator.
    public let fields: [String: BackendJSONValue]

    /// Creates a server event from its discriminator and event-specific fields.
    ///
    /// - Parameters:
    ///   - name: The event discriminator.
    ///   - fields: The event-specific wire fields.
    public init(name: String, fields: [String: BackendJSONValue] = [:]) {
        self.name = name
        self.fields = fields
    }

    /// Decodes an event while separating its discriminator from its fields.
    ///
    /// - Parameter decoder: The decoder containing the event object.
    /// - Throws: A decoding or backend protocol error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: BackendCodingKey.self)
        guard let eventKey = BackendCodingKey(stringValue: "event") else {
            throw BackendProtocolError.malformedMessage
        }
        name = try container.decode(String.self, forKey: eventKey)
        var decoded: [String: BackendJSONValue] = [:]
        decoded.reserveCapacity(container.allKeys.count.saturatingSubtractingOne)
        for key in container.allKeys where key.stringValue != "event" {
            decoded[key.stringValue] = try container.decode(BackendJSONValue.self, forKey: key)
        }
        fields = decoded
    }

    /// Encodes the event discriminator and its event-specific fields.
    ///
    /// - Parameter encoder: The encoder that receives the event object.
    /// - Throws: An encoding error.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: BackendCodingKey.self)
        try container.encode(name, forKey: BackendCodingKey("event"))
        for (key, value) in fields {
            try container.encode(value, forKey: BackendCodingKey(key))
        }
    }

    /// Decodes a supported topology stream event after validating its name.
    ///
    /// - Returns: The typed topology stream event.
    /// - Throws: A decoding error or ``BackendProtocolError/malformedMessage``
    ///   when the event name is not a topology stream event.
    public func topologyStreamEvent() throws -> TopologyStreamEvent {
        let data = try JSONEncoder().encode(self)
        switch name {
        case "topology-delta":
            return .delta(try JSONDecoder().decode(TopologyDelta.self, from: data))
        case "topology-resnapshot-required":
            return .resnapshotRequired(
                try JSONDecoder().decode(BackendResnapshotRequired.self, from: data)
            )
        default:
            throw BackendProtocolError.malformedMessage
        }
    }

    /// Decodes a renderer-worker process rotation notification.
    public func rendererWorkerChanged() throws -> BackendRendererWorkerChanged {
        guard name == "renderer-worker-changed" else {
            throw BackendProtocolError.malformedMessage
        }
        return try JSONDecoder().decode(
            BackendRendererWorkerChanged.self,
            from: JSONEncoder().encode(self)
        )
    }

    /// Decodes exact renderer-owned font metrics for one presentation generation.
    public func rendererPresentationReady() throws -> BackendRendererPresentationReady {
        guard name == "renderer-presentation-ready" else {
            throw BackendProtocolError.malformedMessage
        }
        return try JSONDecoder().decode(
            BackendRendererPresentationReady.self,
            from: JSONEncoder().encode(self)
        )
    }
}

private extension Int {
    var saturatingSubtractingOne: Int { self > 0 ? self - 1 : 0 }
}
