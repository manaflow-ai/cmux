import Foundation

/// A pure, `Equatable` description of a SwiftUI view tree.
///
/// Scripts evaluate to `RenderNode`s; `RenderNodeView` turns them into actual
/// SwiftUI. Keeping this layer free of SwiftUI and `Equatable` is the
/// performance contract: a row recomputes its node only when its input data
/// changes, and the row view stays `.equatable()` over the node so SwiftUI
/// skips untouched rows in a 1000-workspace sidebar.
public struct RenderNode: Equatable {
    /// The view constructor name: "vstack", "text", "image", ...
    public var kind: String
    /// Inline content (text string, image name, shape) keyed by role.
    public var content: [String: RNValue]
    /// Child nodes (for containers).
    public var children: [RenderNode]
    /// Ordered, applied modifiers. Order matters: SwiftUI applies them in turn.
    public var modifiers: [RenderModifier]

    public init(
        kind: String,
        content: [String: RNValue] = [:],
        children: [RenderNode] = [],
        modifiers: [RenderModifier] = []
    ) {
        self.kind = kind
        self.content = content
        self.children = children
        self.modifiers = modifiers
    }

    /// Returns a copy with a modifier appended.
    public func adding(_ modifier: RenderModifier) -> RenderNode {
        var copy = self
        copy.modifiers.append(modifier)
        return copy
    }

    public static let empty = RenderNode(kind: "empty")
}

/// One applied modifier, e.g. `.padding(8)` or `.frame(width: 100)`.
public struct RenderModifier: Equatable {
    public var name: String
    /// Positional values (most modifiers carry exactly one).
    public var values: [RNValue]
    /// Named values (e.g. frame's width/height/alignment).
    public var named: [String: RNValue]

    public init(_ name: String, values: [RNValue] = [], named: [String: RNValue] = [:]) {
        self.name = name
        self.values = values
        self.named = named
    }

    public var first: RNValue? { values.first }
}
