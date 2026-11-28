/// One scene op from the app runtime (ABI "Scene ops"): batches arrive per
/// mount and apply in order.
public nonisolated enum AppSceneOp: Sendable, Hashable {
    case create(id: String, type: String, props: [String: AppJSON])
    /// Partial props; a null value deletes the prop.
    case update(id: String, props: [String: AppJSON])
    /// The node's full ordered child list.
    case children(id: String, children: [String])
    /// The node and its subtree.
    case remove(id: String)
    case root(id: String)

    /// Decodes one op; nil for a malformed or unknown op (skipped).
    public init?(json: AppJSON) {
        guard let op = json["op"]?.stringValue, let id = json["id"]?.stringValue else { return nil }
        switch op {
        case "create":
            guard let type = json["type"]?.stringValue else { return nil }
            self = .create(id: id, type: type, props: json["props"]?.objectValue ?? [:])
        case "update": self = .update(id: id, props: json["props"]?.objectValue ?? [:])
        case "children": self = .children(id: id, children: json["children"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        case "remove": self = .remove(id: id)
        case "root": self = .root(id: id)
        default: return nil
        }
    }

    /// Decodes a batch (`[op, ...]`), skipping malformed ops.
    public static func batch(_ json: AppJSON) -> [AppSceneOp] {
        (json.arrayValue ?? []).compactMap(AppSceneOp.init(json:))
    }
}

/// Node types the native renderer draws (ABI "Node types"). Others are
/// ignored: a newer runtime's node renders nothing on this host.
public nonisolated enum AppSceneNodeType: String, Sendable, Hashable, CaseIterable {
    case vStack = "VStack", hStack = "HStack", zStack = "ZStack", lazyVStack = "LazyVStack"
    case group = "Group", forEach = "ForEach", reorderable = "Reorderable"
    case text = "Text", icon = "Icon", image = "Image", button = "Button", menu = "Menu"
    case spacer = "Spacer", divider = "Divider"
    case circle = "Circle", capsule = "Capsule", rectangle = "Rectangle", roundedRectangle = "RoundedRectangle"
    case progressView = "ProgressView", textField = "TextField"
    case row = "Row", badge = "Badge", emptyState = "EmptyState"

    /// Lays its children out inline in the parent's stack.
    public var isInline: Bool { self == .group || self == .forEach }
}

/// One node of a mounted scene.
public nonisolated struct AppSceneNode: Sendable, Hashable {
    public var type: AppSceneNodeType
    public var props: [String: AppJSON]
    public var children: [String]

    public init(type: AppSceneNodeType, props: [String: AppJSON] = [:], children: [String] = []) {
        self.type = type
        self.props = props
        self.children = children
    }

    public func string(_ key: String) -> String? {
        switch props[key] {
        case .string(let s)?: s
        case .number(let n)?: n.rounded() == n ? String(Int(n)) : String(n)
        default: nil
        }
    }

    public func number(_ key: String) -> Double? { props[key]?.numberValue }
    public func flag(_ key: String) -> Bool { props[key]?.boolValue ?? false }
}
