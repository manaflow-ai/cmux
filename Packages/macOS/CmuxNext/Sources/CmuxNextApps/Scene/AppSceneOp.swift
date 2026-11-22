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

    /// The wire representation used when a page forwards a scene stream.
    public var json: AppJSON {
        switch self {
        case let .create(id, type, props): ["op": "create", "id": .string(id), "type": .string(type), "props": .object(props)]
        case let .update(id, props): ["op": "update", "id": .string(id), "props": .object(props)]
        case let .children(id, children): ["op": "children", "id": .string(id), "children": .array(children.map(AppJSON.string))]
        case let .remove(id): ["op": "remove", "id": .string(id)]
        case let .root(id): ["op": "root", "id": .string(id)]
        }
    }

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
    case circle = "Circle", capsule = "Capsule", rectangle = "Rectangle", roundedRectangle = "RoundedRectangle", line = "Line"
    case progressView = "ProgressView", textField = "TextField"
    case row = "Row", badge = "Badge", emptyState = "EmptyState"
    case toggle = "Toggle", slider = "Slider", panel = "Panel"
    case stat = "Stat", chart = "Chart"

    /// Lays its children out inline in the parent's stack.
    public var isInline: Bool { self == .group || self == .forEach }

    /// The finished components: they take `variant` and `state` (the Rust design check's table,
    /// cmux-tui `src/cli/ext/design_components.rs`; webviews' `sceneComponents.tsx`).
    public var isFinishedComponent: Bool {
        switch self {
        case .row, .badge, .button, .progressView, .stat, .chart, .toggle, .slider, .textField, .image, .emptyState: true
        default: false
        }
    }

    /// The finished components that draw more than `standard`.
    public var hasVariants: Bool {
        switch self {
        case .row, .badge, .button, .progressView, .stat, .chart: true
        default: false
        }
    }
}

/// A finished component's emphasis (`.variant(...)`): anything else draws `standard`.
public nonisolated enum AppSceneComponentVariant: String, Sendable, Hashable {
    case standard, prominent, subtle
}

/// What the host draws in place of a finished component (`.state(...)`).
public nonisolated enum AppSceneComponentState: String, Sendable, Hashable {
    case loading, error, empty
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

    /// The state drawn in place of this node: only a finished component has one.
    public var componentState: AppSceneComponentState? {
        guard type.isFinishedComponent, let name = props["state"]?.stringValue else { return nil }
        return AppSceneComponentState(rawValue: name)
    }

    /// The variant this node draws: `standard` unless it is one of the components with variants.
    public var componentVariant: AppSceneComponentVariant {
        guard type.hasVariants, let name = props["variant"]?.stringValue else { return .standard }
        return AppSceneComponentVariant(rawValue: name) ?? .standard
    }
}
