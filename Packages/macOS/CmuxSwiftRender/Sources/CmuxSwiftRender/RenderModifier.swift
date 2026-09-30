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
    private let deferredContent: DeferredRenderContent?

    public init(name: String, args: [ModifierArg] = [], children: [RenderNode] = []) {
        self.name = name
        self.args = args
        self.children = children
        self.deferredContent = nil
    }

    init(
        name: String,
        args: [ModifierArg] = [],
        children: [RenderNode] = [],
        deferredContent: DeferredRenderContent?
    ) {
        self.name = name
        self.args = args
        self.children = children
        self.deferredContent = deferredContent
    }

    /// Whether this modifier has content that can be attached without
    /// evaluating a deferred builder. This deliberately does not materialize
    /// the builder; callers use it while constructing the surrounding row.
    public var hasContent: Bool {
        !children.isEmpty || deferredContent != nil
    }

    /// Whether the trailing closure was retained for lazy evaluation.
    public var hasDeferredContent: Bool {
        deferredContent != nil
    }

    /// Returns static children directly, or evaluates a deferred builder when requested.
    public func materializedChildren() -> [RenderNode] {
        children.isEmpty ? (deferredContent?.materialize() ?? []) : children
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case args
        case children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        args = try container.decodeIfPresent([ModifierArg].self, forKey: .args) ?? []
        children = try container.decodeIfPresent([RenderNode].self, forKey: .children) ?? []
        deferredContent = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(args, forKey: .args)
        // The out-of-process worker must send a fully serializable tree. Its
        // JSON boundary is therefore the intentional eager-materialization
        // point; the host-side in-process renderer never encodes this payload.
        try container.encode(materializedChildren(), forKey: .children)
    }

    public static func == (lhs: RenderModifier, rhs: RenderModifier) -> Bool {
        // Deferred builders are runtime-only payloads and must not be invoked
        // while comparing render snapshots. Their empty `children` arrays are
        // intentionally compared as-is, preserving a lazy equality path.
        lhs.name == rhs.name
            && lhs.args == rhs.args
            && lhs.children == rhs.children
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
