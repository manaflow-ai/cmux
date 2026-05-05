import Foundation

struct CmuxSurfaceDefinition: Codable, Sendable {
    var type: CmuxSurfaceType
    var name: String?
    var command: String?
    var cwd: String?
    var env: [String: String]?
    var url: String?
    var path: String?
    var focus: Bool?
}

enum CmuxSurfaceType: String, Codable, Sendable {
    case terminal
    case browser
    case markdown
}
