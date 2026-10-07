public import Foundation

/// Exactly-once envelope. Reuse the same `mutationID` for every retry of one
/// logical mutation; the daemon replays the original result.
public struct MutationIdentity: Sendable, Hashable {
    public var origin: String
    public var mutationID: String
    public var expectedGeneration: DaemonGeneration?
    public var expectedRevision: UInt64?

    public init(origin: String, mutationID: String = UUID().uuidString.lowercased(),
                expectedGeneration: DaemonGeneration? = nil, expectedRevision: UInt64? = nil) {
        self.origin = origin
        self.mutationID = mutationID
        self.expectedGeneration = expectedGeneration
        self.expectedRevision = expectedRevision
    }
}

/// Encodes `origin`, `mutation_id`, and CAS guards flat into a request.
struct MutationFields: Encodable {
    var identity: MutationIdentity?

    enum CodingKeys: String, CodingKey {
        case origin, mutationID, expectedGeneration, expectedRevision
    }

    func encode(to encoder: any Encoder) throws {
        guard let identity else { return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identity.origin, forKey: .origin)
        try c.encode(identity.mutationID, forKey: .mutationID)
        try c.encodeIfPresent(identity.expectedGeneration, forKey: .expectedGeneration)
        try c.encodeIfPresent(identity.expectedRevision, forKey: .expectedRevision)
    }
}

/// Absent / `null` / value, for fields where the daemon treats an absent
/// field as unchanged and `null` as clear.
public enum FieldUpdate<Value: Encodable & Sendable & Hashable>: Sendable, Hashable {
    case unchanged
    case clear
    case set(Value)
}

extension KeyedEncodingContainer {
    mutating func encode<V>(_ update: FieldUpdate<V>, forKey key: Key) throws {
        switch update {
        case .unchanged: break
        case .clear: try encodeNil(forKey: key)
        case .set(let value): try encode(value, forKey: key)
        }
    }
}
