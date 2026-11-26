import Foundation

/// The kind of a ``DSLNode`` in the declarative JSON sidebar format.
enum DSLNodeKind: String, Codable, Sendable {
    case vstack
    case hstack
    case zstack
    case text
    case button
    case image
    case spacer
    case divider
}
