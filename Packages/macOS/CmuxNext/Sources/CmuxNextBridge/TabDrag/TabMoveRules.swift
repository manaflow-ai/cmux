public import CmuxNextDaemon
import CmuxNextLayout

// The JSON of the `tab_moves_*` ops (cmux-layout-reducer-ffi `tab_drag_rules.rs`, the rules of
// cmux-layout-reducer `tab_drag_rules`) the app's `TabMoves` follows. Shapes only: nothing here decides.
public nonisolated struct TabMoveRules: Sendable {
    public init() {}

    private enum Wire {
        struct EdgeRequest: Encodable {
            var edge: String
        }

        struct SplitBehindReply: Decodable {
            var edge: String
            var swapsBack: Bool

            enum CodingKeys: String, CodingKey {
                case edge
                case swapsBack = "swaps_back"
            }
        }

        struct FallbackSplitReply: Decodable {
            var direction: String
            var swapsBack: Bool

            enum CodingKeys: String, CodingKey {
                case direction
                case swapsBack = "swaps_back"
            }
        }

        struct DockWidthRequest: Encodable {
            var edge: String
            var width: Double?
            var beside: Double?
            var askedBeside: Bool

            enum CodingKeys: String, CodingKey {
                case edge
                case width
                case beside
                case askedBeside = "asked_beside"
            }
        }

        struct DockWidthReply: Decodable {
            var width: Double?
            var needsBeside: Bool?

            enum CodingKeys: String, CodingKey {
                case width
                case needsBeside = "needs_beside"
            }
        }

        struct ColumnAnchorRequest: Encodable {
            var columnPanes: [String]
            var screenPanes: [String]
            var avoiding: String?

            enum CodingKeys: String, CodingKey {
                case columnPanes = "column_panes"
                case screenPanes = "screen_panes"
                case avoiding
            }
        }

        struct ColumnAnchorReply: Decodable {
            var pane: String?
        }
    }

    /// Where the New Tab page opens for every tab of a pane dropped on its own `edge`, and whether the
    /// panes swap after; nil when the reducer does not answer.
    public func splitBehind(_ edge: PaneEdge) -> (edge: PaneEdge, swapsBack: Bool)? {
        let reply = LayoutReducerJSON().call("tab_moves_split_behind", Wire.EdgeRequest(edge: edge.rawValue),
                                             as: Wire.SplitBehindReply.self)
        guard let reply, let edge = PaneEdge(rawValue: reply.edge) else { return nil }
        return (edge, reply.swapsBack)
    }

    /// The split an older daemon makes for `edge`, and whether the new pane swaps with its target; nil
    /// when the reducer does not answer.
    public func fallbackSplit(_ edge: PaneEdge) -> (direction: SplitDirection, swapsBack: Bool)? {
        let reply = LayoutReducerJSON().call("tab_moves_fallback_split", Wire.EdgeRequest(edge: edge.rawValue),
                                             as: Wire.FallbackSplitReply.self)
        guard let reply, let direction = SplitDirection(rawValue: reply.direction) else { return nil }
        return (direction, reply.swapsBack)
    }

    /// A new dock's width: `width` when given, else Rust's share for `edge`; a right dock asks
    /// `beside` (the width of a new column next to its anchor) once. Nil when the reducer does not answer.
    public func dockWidth(edge: String, width: Double?, beside: () -> Double?) -> Double? {
        let json = LayoutReducerJSON()
        let first = Wire.DockWidthRequest(edge: edge, width: width, beside: nil, askedBeside: false)
        guard let reply = json.call("tab_moves_dock_width", first, as: Wire.DockWidthReply.self) else { return nil }
        if let width = reply.width { return width }
        guard reply.needsBeside == true else { return nil }
        let second = Wire.DockWidthRequest(edge: edge, width: width, beside: beside(), askedBeside: true)
        return json.call("tab_moves_dock_width", second, as: Wire.DockWidthReply.self)?.width
    }

    /// The pane that anchors a new column: the column's last pane, else the screen's first, never
    /// `avoiding`. Nil when there is none or the reducer does not answer.
    public func columnAnchor(column: [String], screen: [String], avoiding: String?) -> String? {
        let request = Wire.ColumnAnchorRequest(columnPanes: column, screenPanes: screen, avoiding: avoiding)
        return LayoutReducerJSON().call("tab_moves_column_anchor", request, as: Wire.ColumnAnchorReply.self)?.pane
    }
}
