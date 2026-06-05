import Foundation

/// The top-level declarative JSON sidebar document loaded from disk.
struct DSLDocument: Codable, Equatable, Sendable {
    var version: Int
    var root: DSLNode
}
