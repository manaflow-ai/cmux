import Foundation

/// A declarative action attached to an interactive JSON-DSL node.
struct DSLAction: Codable, Equatable, Sendable {
    var type: String
    var message: String?
}
