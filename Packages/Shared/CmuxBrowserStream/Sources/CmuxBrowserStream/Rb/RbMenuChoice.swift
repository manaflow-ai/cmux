import CmuxMobileWire

/// The user's answer to a menu (`rb.menu.result`).
public enum RbMenuChoice: Hashable, Sendable {
    case cancel
    case command(id: Int64)
    case indices([UInt32])

    var jsonValue: JSONValue {
        switch self {
        case .cancel: .object(["choice": .string("cancel")])
        case .command(let id): .object(["choice": .string("command"), "id": .int(id)])
        case .indices(let indices): .object(["choice": .string("indices"), "indices": .array(indices.map { .int(Int64($0)) })])
        }
    }

    init(json: JSONValue) throws(RdWireError) {
        let r = try RbJSONReader(json)
        switch try r.string("choice") {
        case "cancel": self = .cancel
        case "command": self = .command(id: try r.int("id"))
        case "indices":
            var out: [UInt32] = []
            for value in try r.array("indices") {
                guard case .int(let index) = value, let index = UInt32(exactly: index) else { throw RdWireError("indices") }
                out.append(index)
            }
            self = .indices(out)
        case let other: throw RdWireError("menu choice \(other)")
        }
    }
}
