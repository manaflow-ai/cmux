import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout

/// What the Rust drop rules read and answer for a link drop (`drop_link_plan`): the layout target
/// as cmux-layout-reducer `drop_rules` names it. No rule lives here: the reply names a plan kind,
/// and the ids it carries are the target's.
enum LinkDropWire {
    /// `"paneCenter"`, `{"paneEdge": "left"}`, `"newColumn"` or `"newDock"`.
    struct Target: Encodable {
        var kind: String, edge: String?

        init(_ target: LayoutDropTarget) {
            switch target {
            case .pane(_, .center): kind = "paneCenter"
            case .pane(_, let zone): kind = "paneEdge"; edge = zone.rawValue
            case .newColumn: kind = "newColumn"
            case .newDock: kind = "newDock"
            }
        }

        func encode(to encoder: any Encoder) throws {
            if let edge {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(edge, forKey: Key(kind))
            } else {
                var container = encoder.singleValueContainer()
                try container.encode(kind)
            }
        }

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ string: String) { stringValue = string }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue _: Int) { nil }
        }
    }

    struct Request: Encodable { var target: Target, takesTabs: Bool }

    struct Reply: Decodable {
        var plan: String, edge: String?

        func plan(for target: LayoutDropTarget) -> LinkDropPlan? {
            switch (plan, target) {
            case ("tab", .pane(let pane, _)): .tab(in: pane)
            case ("split", .pane(let pane, _)): edge.flatMap(PaneEdge.init(rawValue:)).map { .split(pane, edge: $0) }
            case ("column", .newColumn(let screen, let after)): .column(screen: screen, after: after)
            case ("dock", .newDock(let screen, let edge)): .dock(screen: screen, edge: edge)
            default: nil
            }
        }
    }
}
