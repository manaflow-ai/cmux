import Foundation
import Observation

/// One property value on a scene node. Props arrive from the JS runtime as
/// scalars only; reactive props are resolved to scalars JS-side before they
/// cross the bridge.
public enum ScenePropValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    var stringValue: String? {
        if case let .string(v) = self { return v }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case let .number(v): return v
        case let .string(s): return Double(s)
        case .bool: return nil
        }
    }

    var boolValue: Bool? {
        if case let .bool(v) = self { return v }
        return nil
    }

    init?(json: Any) {
        // `as? Bool` is NOT a safe discriminator: NSNumber(0)/NSNumber(1)
        // bridge to Bool successfully, which silently turned numeric props
        // like lineLimit(1) and opacity(1) into booleans. JSONSerialization
        // produces CFBoolean for JSON true/false and CFNumber for numbers,
        // so the type id is the reliable test.
        if let n = json as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        } else if let s = json as? String {
            self = .string(s)
        } else {
            return nil
        }
    }
}

/// One retained scene node. `@Observable` so a SwiftUI view that reads this
/// node's `props`/`children` re-renders when — and only when — this node
/// changes. That is the fine-grained update path: a JS effect that changes one
/// text prop touches one node, which invalidates one view.
@MainActor
@Observable
public final class SceneNode: Identifiable {
    public let id: String
    public let type: String
    public internal(set) var props: [String: ScenePropValue] = [:]
    public internal(set) var children: [String] = []

    init(id: String, type: String) {
        self.id = id
        self.type = type
    }

    func string(_ key: String) -> String? { props[key]?.stringValue }
    func double(_ key: String) -> Double? { props[key]?.doubleValue }
    func bool(_ key: String) -> Bool { props[key]?.boolValue ?? false }
}

/// The retained scene graph the JS runtime mutates through ops. Nodes are
/// looked up by id; the node dictionary itself is intentionally not observed
/// (`@ObservationIgnored`) so structural edits invalidate only the parents
/// whose `children` arrays changed, not every mounted view.
@MainActor
@Observable
public final class SceneStore {
    public private(set) var rootId: String?
    @ObservationIgnored private var nodes: [String: SceneNode] = [:]

    public init() {}

    public func node(_ id: String) -> SceneNode? {
        nodes[id]
    }

    /// Applies one JSON-decoded op batch from the runtime, in order.
    func apply(opsJSON: String) {
        guard let data = opsJSON.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let ops = raw as? [[String: Any]] else { return }
        for op in ops {
            apply(op)
        }
    }

    private func apply(_ op: [String: Any]) {
        guard let kind = op["op"] as? String, let id = op["id"] as? String else { return }
        switch kind {
        case "create":
            guard let type = op["type"] as? String else { return }
            nodes[id] = SceneNode(id: id, type: type)
        case "update":
            guard let node = nodes[id], let key = op["key"] as? String else { return }
            let value = op["value"].flatMap { ScenePropValue(json: $0) }
            if node.props[key] != value {
                if let value {
                    node.props[key] = value
                } else {
                    node.props.removeValue(forKey: key)
                }
            }
        case "children":
            guard let node = nodes[id], let children = op["children"] as? [String] else { return }
            if node.children != children {
                node.children = children
            }
        case "append":
            guard let node = nodes[id], let child = op["child"] as? String else { return }
            if !node.children.contains(child) {
                node.children.append(child)
            }
        case "remove":
            nodes.removeValue(forKey: id)
            if rootId == id { rootId = nil }
        case "root":
            rootId = id
        default:
            break
        }
    }
}
