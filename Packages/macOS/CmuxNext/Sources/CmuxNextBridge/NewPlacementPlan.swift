@_implementationOnly import CCmuxLayoutReducerFFI
public import Foundation

/// Where New ▸ Kind ▸ Placement opens its item and how it is made, asked of the layout reducer
/// (`new_placement` of `cmux_layout_reducer_json`, cmux-layout-reducer new_placement.rs, with its
/// tests). The app reads the facts (the pane's daemon) and runs the plan; the rule stays in Rust.
public nonisolated struct NewPlacementPlan: Equatable, Sendable {
    /// The layout op the placement asks for.
    public enum Op: Equatable, Sendable {
        /// A new split of the pane on `edge` (`right`, `left`, `top`, `bottom`).
        case split(edge: String)
        /// A new strip column after the pane's column, or before it when `left`.
        case column(left: Bool)
        case row
        case tab
        case workspace
        case window
    }

    public var op: Op
    /// The kind's own create makes it there in one daemon commit; else it is made unselected in
    /// the pane and moved there in one daemon move.
    public var madeInPlace: Bool

    public init(op: Op, madeInPlace: Bool) {
        self.op = op
        self.madeInPlace = madeInPlace
    }

    /// The plan for `kind` (`terminal`, `browser`, `agentChat`, `newTabPage`) at `place` (a fork
    /// destination's raw value). `tabSplit`: the pane's daemon makes a chat in its split
    /// (`conversation-tab-split-v1`). Nil when the reducer does not answer (an app FFI from before
    /// the operation): the caller then makes the item and moves it, which reaches every place.
    public init?(kind: String, place: String, tabSplit: Bool) {
        struct Request: Encodable { var kind: String, placement: String, tabSplit: Bool }
        struct Reply: Decodable { var op: String, edge: String?, left: Bool?, make: String }
        guard let data = try? JSONEncoder().encode(Request(kind: kind, placement: place, tabSplit: tabSplit)) else { return nil }
        var output = [UInt8](repeating: 0, count: 256), length = 0
        let code: Int32 = data.withUnsafeBytes { request in
            "new_placement".withCString { operation in
                output.withUnsafeMutableBytes { buffer in
                    cmux_layout_reducer_json(request.bindMemory(to: UInt8.self).baseAddress, data.count, operation,
                                             buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &length)
                }
            }
        }
        guard code == CMUX_LAYOUT_REDUCER_OK, length <= output.count,
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(output.prefix(length))) else { return nil }
        let op: Op
        switch reply.op {
        case "split": guard let edge = reply.edge else { return nil }; op = .split(edge: edge)
        case "column": op = .column(left: reply.left ?? false)
        case "row": op = .row
        case "tab": op = .tab
        case "workspace": op = .workspace
        case "window": op = .window
        default: return nil
        }
        self.init(op: op, madeInPlace: reply.make == "in_place")
    }

    /// The op of `place` alone, made then moved: what runs when the reducer does not answer.
    public static func fallback(place: String) -> NewPlacementPlan? {
        let op: Op? = switch place {
        case "right": .split(edge: "right")
        case "left": .split(edge: "left")
        case "up": .split(edge: "top")
        case "down": .split(edge: "bottom")
        case "columnRight": .column(left: false)
        case "columnLeft": .column(left: true)
        case "row": .row
        case "tab": .tab
        case "workspace": .workspace
        case "window": .window
        default: nil
        }
        return op.map { NewPlacementPlan(op: $0, madeInPlace: $0 == .tab) }
    }
}
