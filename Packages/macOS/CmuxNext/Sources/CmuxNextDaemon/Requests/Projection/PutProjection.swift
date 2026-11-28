import Foundation

/// CAS write of an opaque (<= 1 MiB) per-window/profile document.
public struct PutFrontendProjectionRequest: DaemonRequest {
    public typealias Response = FrontendProjection
    public static let command = "put-frontend-projection"
    public var frontend: String
    public var scope: ProjectionScope
    public var subjectKey: String
    public var schemaVersion: UInt32
    public var projection: JSONValue
    public var expectedProjectionRevision: UInt64?
    public var mutation: MutationIdentity

    public init(frontend: String, scope: ProjectionScope, subjectKey: String, schemaVersion: UInt32,
                projection: JSONValue, expectedProjectionRevision: UInt64? = nil, mutation: MutationIdentity) {
        self.frontend = frontend
        self.scope = scope
        self.subjectKey = subjectKey
        self.schemaVersion = schemaVersion
        self.projection = projection
        self.expectedProjectionRevision = expectedProjectionRevision
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey { case frontend, scope, subjectKey, schemaVersion, projection, expectedProjectionRevision }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(frontend, forKey: .frontend)
        try c.encode(scope, forKey: .scope)
        try c.encode(subjectKey, forKey: .subjectKey)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(projection, forKey: .projection)
        try c.encodeIfPresent(expectedProjectionRevision, forKey: .expectedProjectionRevision)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}
