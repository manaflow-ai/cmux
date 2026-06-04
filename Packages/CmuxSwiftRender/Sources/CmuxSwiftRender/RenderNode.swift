/// The intermediate representation an interpreted Swift `View` expression
/// lowers to, before a SwiftUI bridge turns it into real views.
///
/// This IR is the leaf-bridge boundary: the interpreter handles the Swift
/// *language* (calls, closures, later loops/state), and a thin SwiftUI
/// layer maps each ``Kind`` to the real compiled view initializer. The set
/// of kinds is the framework bridge that grows over time; the language
/// coverage is what makes the approach general.
public struct RenderNode: Codable, Sendable, Equatable {
    /// The view primitive this node represents.
    public enum Kind: String, Codable, Sendable {
        case vstack
        case hstack
        case zstack
        /// A horizontally resizable split: children are columns separated by
        /// a draggable divider. The host owns the split fraction.
        case hsplit
        /// A vertical list whose rows can be drag-and-drop reordered; the
        /// drop is persisted via ``ReorderSpec``.
        case reorderable
        case text
        case button
        case image
        case spacer
        case divider
        // Shape views (fillable via `.fill`/`.foregroundColor`, sizable via `.frame`).
        case rectangle
        case roundedRectangle
        case capsule
        case circle
    }

    public var kind: Kind
    public var text: String?
    /// SF Symbol name for `.image` nodes (`Image(systemName:)`).
    public var systemName: String?
    public var spacing: Double?
    /// Corner radius for `.roundedRectangle` (`RoundedRectangle(cornerRadius:)`).
    public var cornerRadius: Double?
    public var children: [RenderNode]
    public var modifiers: [RenderModifier]
    public var action: ButtonAction?
    /// Drag-and-drop reorder spec for `.reorderable` nodes.
    public var reorder: ReorderSpec?

    public init(
        kind: Kind,
        text: String? = nil,
        systemName: String? = nil,
        spacing: Double? = nil,
        cornerRadius: Double? = nil,
        children: [RenderNode] = [],
        modifiers: [RenderModifier] = [],
        action: ButtonAction? = nil,
        reorder: ReorderSpec? = nil
    ) {
        self.kind = kind
        self.text = text
        self.systemName = systemName
        self.spacing = spacing
        self.cornerRadius = cornerRadius
        self.children = children
        self.modifiers = modifiers
        self.action = action
        self.reorder = reorder
    }
}
