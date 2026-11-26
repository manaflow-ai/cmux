import CmuxNextDesign
import CmuxNextLayout
import CoreGraphics
import Foundation

// The JSON of the `tab_drag_rule_*` ops (cmux-layout-reducer-ffi `tab_drag_rules.rs`, the shapes of
// cmux-layout-reducer `tab_drag_rules`). Shapes only: nothing here decides.
nonisolated extension TabDragResolver {
    enum Wire {
        struct Point: Codable {
            var x: Double
            var y: Double

            init(_ point: CGPoint) {
                x = Double(point.x)
                y = Double(point.y)
            }

            var cgPoint: CGPoint { CGPoint(x: x, y: y) }
        }

        struct Context: Encodable {
            var sourcePaneID: String
            var sourcePaneTabCount: Int
            var sourceWorkspaceID: String
            var sourceWorkspaceTabCount: Int
            var draggedTabCount: Int
            var sourceWindowWorkspaceCount: Int
            var sourceStripID: String?
            var sourceIndex: Int?
            var sourceGroupID: String?
            var isGroupDrag: Bool
            var sourceStaysPut: Bool

            enum CodingKeys: String, CodingKey {
                case sourcePaneID = "source_pane_id"
                case sourcePaneTabCount = "source_pane_tab_count"
                case sourceWorkspaceID = "source_workspace_id"
                case sourceWorkspaceTabCount = "source_workspace_tab_count"
                case draggedTabCount = "dragged_tab_count"
                case sourceWindowWorkspaceCount = "source_window_workspace_count"
                case sourceStripID = "source_strip_id"
                case sourceIndex = "source_index"
                case sourceGroupID = "source_group_id"
                case isGroupDrag = "is_group_drag"
                case sourceStaysPut = "source_stays_put"
            }

            init(_ context: TabDragContext) {
                sourcePaneID = context.sourcePaneID
                sourcePaneTabCount = context.sourcePaneTabCount
                sourceWorkspaceID = context.sourceWorkspaceID
                sourceWorkspaceTabCount = context.sourceWorkspaceTabCount
                draggedTabCount = context.draggedTabCount
                sourceWindowWorkspaceCount = context.sourceWindowWorkspaceCount
                sourceStripID = context.sourceStripID?.uuidString
                sourceIndex = context.sourceIndex
                sourceGroupID = context.sourceGroupID
                isGroupDrag = context.isGroupDrag
                sourceStaysPut = context.sourceStaysPut
            }
        }

        struct Kind: Encodable {
            var kind: String
            var stripID: String?
            var index: Int?
            var groupID: String?
            var paneID: String?
            var edge: String?
            var screenID: String?
            var afterColumnID: String?
            var id: String?

            enum CodingKeys: String, CodingKey {
                case kind
                case stripID = "strip_id"
                case index
                case groupID = "group_id"
                case paneID = "pane_id"
                case edge
                case screenID = "screen_id"
                case afterColumnID = "after_column_id"
                case id
            }

            init(_ kind: TabDropKind) {
                switch kind {
                case .strip(let strip, let index, let group):
                    self.kind = "strip"
                    stripID = strip.uuidString
                    self.index = index
                    groupID = group
                case .newSplit(let pane, let edge):
                    self.kind = "new_split"
                    paneID = pane
                    self.edge = Wire.edge(edge)
                case .newColumn(let screen, let after):
                    self.kind = "new_column"
                    screenID = screen
                    afterColumnID = after
                case .newDock(let screen, let edge):
                    self.kind = "new_dock"
                    screenID = screen
                    self.edge = edge
                case .newWorkspace(let group, let index):
                    self.kind = "new_workspace"
                    groupID = group
                    self.index = index
                case .workspace(let id):
                    self.kind = "workspace"
                    self.id = id
                }
            }
        }

        struct VerdictRequest: Encodable {
            var kind: Kind
            var context: Context
        }

        struct ResolveRequest: Encodable {
            var kind: Kind?
            var refusedReason: String?
            var insideWindow: Bool
            var point: Point
            var context: Context

            enum CodingKeys: String, CodingKey {
                case kind
                case refusedReason = "refused_reason"
                case insideWindow = "inside_window"
                case point
                case context
            }
        }

        struct ContextRequest: Encodable {
            var context: Context
            var pane: String?
        }

        struct Refusal: Decodable {
            var code: String
            var reason: String?

            var refusal: TabDropRefusal? {
                switch code {
                case "column_before_first": .columnBeforeFirst
                case "group_dock": .groupDock
                case "stays_put": .staysPut
                case "surface": reason.map(TabDropRefusal.surface)
                default: nil
                }
            }
        }

        struct VerdictReply: Decodable {
            var verdict: String
            var refusal: Refusal?

            var tabDropVerdict: TabDropVerdict? {
                switch verdict {
                case "accept": .accept
                case "stay": .stay
                case "refuse": refusal?.refusal.map(TabDropVerdict.refuse)
                default: nil
                }
            }
        }

        struct Outcome: Decodable {
            var outcome: String
            var stripID: String?
            var index: Int?
            var groupID: String?
            var paneID: String?
            var edge: String?
            var screenID: String?
            var afterColumnID: String?
            var id: String?
            var point: Point?

            enum CodingKeys: String, CodingKey {
                case outcome
                case stripID = "strip_id"
                case index
                case groupID = "group_id"
                case paneID = "pane_id"
                case edge
                case screenID = "screen_id"
                case afterColumnID = "after_column_id"
                case id
                case point
            }

            /// Nil for a shape this build does not know: the caller cancels.
            var tabDragOutcome: TabDragOutcome? {
                switch outcome {
                case "strip":
                    guard let strip = stripID.flatMap(UUID.init(uuidString:)), let index else { return nil }
                    return .strip(stripID: strip, index: index, groupID: groupID)
                case "new_split":
                    guard let paneID, let edge = edge.flatMap(Wire.edge(named:)) else { return nil }
                    return .newSplit(paneID: paneID, edge: edge)
                case "new_column":
                    guard let screenID, let afterColumnID else { return nil }
                    return .newColumn(screenID: screenID, afterColumnID: afterColumnID)
                case "new_dock":
                    guard let screenID, let edge else { return nil }
                    return .newDock(screenID: screenID, edge: edge)
                case "new_workspace":
                    return .newWorkspace(groupID: groupID, index: index)
                case "workspace":
                    return id.map { .workspace(id: $0) }
                case "tear_off":
                    return point.map { .tearOff(screenPoint: $0.cgPoint) }
                case "move_window":
                    return point.map { .moveWindow(screenPoint: $0.cgPoint) }
                case "move_workspace_to_new_window":
                    return point.map { .moveWorkspaceToNewWindow(screenPoint: $0.cgPoint) }
                case "move_workspace":
                    return .moveWorkspace(groupID: groupID, index: index)
                case "cancel":
                    return .cancel
                default:
                    return nil
                }
            }
        }

        struct ResolveReply: Decodable {
            var preview: String
            var refusal: Refusal?
            var outcome: Outcome
        }

        struct ContextReply: Decodable {
            var emptiesSourcePane: Bool
            var emptiesSourceWorkspace: Bool
            var splitsBehind: Bool

            enum CodingKeys: String, CodingKey {
                case emptiesSourcePane = "empties_source_pane"
                case emptiesSourceWorkspace = "empties_source_workspace"
                case splitsBehind = "splits_behind"
            }
        }

        static func edge(_ edge: TabDropEdge) -> String {
            switch edge {
            case .left: "left"
            case .right: "right"
            case .top: "top"
            case .bottom: "bottom"
            }
        }

        static func edge(named name: String) -> TabDropEdge? {
            switch name {
            case "left": .left
            case "right": .right
            case "top": .top
            case "bottom": .bottom
            default: nil
            }
        }

        /// The source's counts as Rust reads them; nil when the reducer does not answer.
        static func context(_ context: TabDragContext, pane: String? = nil) -> ContextReply? {
            LayoutReducerJSON().call("tab_drag_rule_context", ContextRequest(context: Context(context), pane: pane),
                                     as: ContextReply.self)
        }
    }
}
