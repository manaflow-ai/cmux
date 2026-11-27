import Foundation

public enum ProjectionScope: String, Sendable, Hashable, Codable {
    case personal, shared
}

public struct GetFrontendProjectionRequest: DaemonRequest {
    public typealias Response = FrontendProjection
    public static let command = "get-frontend-projection"
    public var frontend: String
    public var scope: ProjectionScope
    public var subjectKey: String
    public init(frontend: String, scope: ProjectionScope, subjectKey: String) {
        self.frontend = frontend
        self.scope = scope
        self.subjectKey = subjectKey
    }
}
