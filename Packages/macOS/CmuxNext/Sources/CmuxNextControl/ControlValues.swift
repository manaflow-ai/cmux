public import CmuxNextSettings

/// A reference to one object (`--target tab-group:g1`), in wire form.
public struct ControlTargetRef: Sendable, Hashable, CustomStringConvertible {
    /// Target kind as its CLI prefix (`workspace-group`).
    public var kind: String
    public var id: String

    public init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }

    public var description: String { "\(kind):\(id)" }

    var json: JSONValue { .object(["kind": .string(kind), "id": .string(id)]) }
}

/// A validated argument value.
public enum ControlValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case target(ControlTargetRef)

    var json: JSONValue {
        switch self {
        case .string(let value): .string(value)
        case .int(let value): JSONValue(value)
        case .bool(let value): .bool(value)
        case .target(let ref): .string(ref.description)
        }
    }
}

/// A tab id (`tab_…`), or the surface UUID the cmux CLI prints (the same 32 hex digits, with
/// dashes), as the tab id (`resources`, `agent.chat.perf`).
public func normalizedControlTabID(_ raw: String) -> String {
    let hex = raw.replacingOccurrences(of: "-", with: "").lowercased()
    guard !raw.hasPrefix("tab_"), hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return raw }
    return "tab_" + hex
}
