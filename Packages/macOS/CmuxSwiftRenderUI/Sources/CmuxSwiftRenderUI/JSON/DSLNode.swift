import Foundation

/// One node in the declarative JSON sidebar tree.
///
/// A single value type with optional fields keyed by ``DSLNodeKind`` keeps the
/// JSON trivial to author and the renderer a single recursive `switch`.
struct DSLNode: Codable, Equatable, Sendable, Identifiable {
    /// Not decoded; a stable identity per decoded node for `ForEach`.
    let id = UUID()
    var type: DSLNodeKind
    var children: [DSLNode]?

    // Layout
    var spacing: Double?
    var alignment: String?
    var padding: Double?

    // Content / style
    var text: String?
    var title: String?
    var font: String?
    var weight: String?
    var color: String?
    var background: String?
    var systemName: String?
    var size: Double?
    var action: DSLAction?

    enum CodingKeys: String, CodingKey {
        case type, children, spacing, alignment, padding
        case text, title, font, weight, color, background, systemName, size, action
    }
}
