import CCmuxLayoutReducerFFI
import Foundation

/// JSON marshalling only. Rust predicts the tree; ScreenGeometry resolves its AppKit pixels.
nonisolated enum NewTabDividerLayout {
    static let newPane = PaneID(rawValue: "__new-tab-divider-pane")

    static func predict(_ tree: SplitNode, split: SplitID, ratio: Double) -> SplitNode? {
        let request: [String: Any] = ["tree": wire(tree), "split": split.rawValue, "ratio": ratio]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var output = [UInt8](repeating: 0, count: data.count + 2048)
        var length = 0
        let code = data.withUnsafeBytes { input in
            "new_tab_split_layout".withCString { operation in
                output.withUnsafeMutableBytes { buffer in
                    cmux_layout_reducer_json(input.bindMemory(to: UInt8.self).baseAddress, data.count, operation,
                                             buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &length)
                }
            }
        }
        guard code == CMUX_LAYOUT_REDUCER_OK, length <= output.count,
              let value = try? JSONSerialization.jsonObject(with: Data(output.prefix(length)), options: .fragmentsAllowed) else { return nil }
        return node(value)
    }

    private static func wire(_ tree: SplitNode) -> [String: Any] {
        switch tree {
        case let .leaf(pane): ["pane": pane.rawValue]
        case let .split(id, axis, ratio, a, b):
            ["split": id.rawValue, "axis": axis.rawValue, "ratio": ratio, "a": wire(a), "b": wire(b)]
        }
    }

    private static func node(_ value: Any) -> SplitNode? {
        guard let value = value as? [String: Any] else { return nil }
        if let pane = value["pane"] as? String { return .leaf(PaneID(rawValue: pane)) }
        guard let id = value["split"] as? String, let axis = value["axis"] as? String,
              let axis = SplitAxis(rawValue: axis), let ratio = value["ratio"] as? Double,
              let a = value["a"].flatMap(node), let b = value["b"].flatMap(node) else { return nil }
        return .split(SplitID(rawValue: id), axis: axis, ratio: ratio, a: a, b: b)
    }
}
