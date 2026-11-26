/// A modifier applied to a ``RenderNode`` (e.g. `.frame(maxWidth: .infinity)`),
/// captured with its labeled argument list so multi-argument modifiers like
/// `.frame` can be applied precisely.
public struct RenderModifier: Codable, Sendable, Equatable {
    public let name: String
    public let args: [ModifierArg]
    /// The view subtree from a modifier's trailing closure, e.g. the content of
    /// `.overlay { ... }` / `.background { ... }` / `.mask { ... }`. Empty for
    /// value-only modifiers.
    public let children: [RenderNode]

    public init(name: String, args: [ModifierArg] = [], children: [RenderNode] = []) {
        self.name = name
        self.args = args
        self.children = children
    }

    /// The first unlabeled argument value (or the first argument), for
    /// single-argument modifiers like `.padding(8)` or `.foregroundColor(.blue)`.
    public var firstValue: String? {
        (args.first(where: { $0.label == nil }) ?? args.first)?.value
    }

    /// The value of the argument with `label`, if present.
    public func value(_ label: String) -> String? {
        args.first { $0.label == label }?.value
    }
}
