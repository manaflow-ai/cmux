import Foundation

public enum ProjectionScope: String, Sendable, Hashable, Codable {
    case personal, shared
}

public struct FrontendProjection: Decodable, Sendable, Equatable {
    public var frontend: String
    public var scope: String
    public var subjectKey: String
    public var schemaVersion: UInt32
    public var projectionRevision: UInt64
    /// Null when the projection does not exist yet (revision 0).
    public var projection: JSONValue
    public var replayed: Bool?

    enum CodingKeys: String, CodingKey {
        case frontend, scope, projection, replayed
        case subjectKey = "subject_key"
        case schemaVersion = "schema_version"
        case projectionRevision = "projection_revision"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frontend = try c.decode(String.self, forKey: .frontend)
        scope = try c.decode(String.self, forKey: .scope)
        subjectKey = try c.decode(String.self, forKey: .subjectKey)
        schemaVersion = try c.decodeIfPresent(UInt32.self, forKey: .schemaVersion) ?? 0
        projectionRevision = try c.decodeIfPresent(UInt64.self, forKey: .projectionRevision) ?? 0
        projection = try c.decodeIfPresent(JSONValue.self, forKey: .projection) ?? .null
        replayed = try c.decodeIfPresent(Bool.self, forKey: .replayed)
    }
}
