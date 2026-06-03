import Foundation

/// The top-level declarative JSON sidebar document loaded from disk.
public struct DSLDocument: Codable, Equatable, Sendable {
    var version: Int
    var root: DSLNode
}
