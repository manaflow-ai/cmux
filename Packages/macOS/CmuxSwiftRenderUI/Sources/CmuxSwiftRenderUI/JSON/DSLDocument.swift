import Foundation

/// The top-level declarative JSON sidebar document loaded from disk.
///
/// Public so ``CustomSidebarModel/State`` (whose `.json` case carries it) can
/// cross the package boundary to the out-of-process render worker; the fields
/// stay internal — only this package decodes and renders documents.
public struct DSLDocument: Codable, Equatable, Sendable {
    /// Document schema version.
    var version: Int
    /// The root declarative node.
    var root: DSLNode
}
