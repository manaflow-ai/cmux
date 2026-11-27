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
        /// A lazily-built vertical stack (`LazyVStack`) for long row lists.
        case lazyVStack
        /// A lazily-built horizontal stack (`LazyHStack`).
        case lazyHStack
        /// A layout-transparent container (`Group`); also the lowering of
        /// `EmptyView` (a group with no children).
        case group
        /// `List { ... }`, rendered as a plain sidebar-styled list.
        case list
        /// A `Section` with an optional header (``text``) above its children.
        case section
        /// A horizontal `ScrollView(.horizontal)` wrapping its children in an
        /// `HStack`. Vertical scroll views stay passthrough (the sidebar host
        /// already scrolls vertically) and lower to ``vstack``.
        case hscroll
        /// `Grid { GridRow { ... } ... }` for aligned columns.
        case grid
        /// `GridRow { ... }`, a row within a ``grid``.
        case gridRow
        /// `LazyVGrid` / `LazyHGrid`, rendered with adaptive columns/rows.
        case lazyVGrid
        case lazyHGrid
        /// `ViewThatFits`: children are candidates; SwiftUI picks the first fit.
        case viewThatFits
        /// A horizontally resizable split: children are columns separated by
        /// a draggable divider. The host owns the split fraction.
        case hsplit
        /// A vertical list whose rows can be drag-and-drop reordered; the
        /// drop is persisted via ``ReorderSpec``.
        case reorderable
        case text
        /// `Label(title, systemImage:)`: ``text`` is the title, ``systemName``
        /// the SF Symbol.
        case label
        case button
        case image
        case spacer
        case divider
        // Shape views (fillable via `.fill`/`.foregroundColor`, sizable via `.frame`).
        case rectangle
        case roundedRectangle
        case capsule
        case circle
        case ellipse
        /// `UnevenRoundedRectangle`; rendered with a uniform ``cornerRadius``
        /// approximation.
        case unevenRoundedRectangle
        /// `ProgressView()` (indeterminate) or `ProgressView(value:)`
        /// (determinate via ``value``); optional ``text`` label.
        case progressView
        /// `Gauge(value:)`, determinate via ``value``; optional ``text`` label.
        case gauge
        /// `Menu(title) { ... }`: ``text`` is the label, children the items.
        case menu
        /// `LinearGradient` / `RadialGradient` / `AngularGradient`: ``colors``
        /// holds the stops and ``points`` the start/end (linear) or center
        /// (radial/angular) `UnitPoint` tokens.
        case linearGradient
        case radialGradient
        case angularGradient
    }

    public var kind: Kind
    public var text: String?
    /// SF Symbol name for `.image` nodes (`Image(systemName:)`).
    public var systemName: String?
    public var spacing: Double?
    /// Corner radius for `.roundedRectangle` (`RoundedRectangle(cornerRadius:)`).
    public var cornerRadius: Double?
    /// Determinate value (0...1 after normalization) for `.progressView` / `.gauge`.
    public var value: Double?
    /// Gradient color stops (hex/token strings) for the gradient kinds.
    public var colors: [String]
    /// Gradient `UnitPoint` tokens (e.g. `top`, `bottomTrailing`) — start/end
    /// for linear, center for radial/angular.
    public var points: [String]
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
        value: Double? = nil,
        colors: [String] = [],
        points: [String] = [],
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
        self.value = value
        self.colors = colors
        self.points = points
        self.children = children
        self.modifiers = modifiers
        self.action = action
        self.reorder = reorder
    }
}
