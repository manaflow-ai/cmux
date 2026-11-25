import CmuxNextDesign
import CoreGraphics

/// What the Rust drop rules read and answer for a workspace drag (`drop_workspace_outcome`): the
/// drag's types as cmux-layout-reducer `drop_rules` names them. No rule lives here: the reply
/// names a target kind, and the payload it carries is the hit the app sent.
enum WorkspaceDragWire {
    struct PaneHit: Encodable { var splitEdge: String? }

    struct Drag: Encodable {
        var window: String?, sidebarHit: String?, layoutHit: PaneHit?, placesBeside: Bool
        var sourceWindow: String?, draggingAllOfSource: Bool, isGroup: Bool, besideEdge: String?

        init(windowID: String?, sidebarHit: WorkspaceDropTarget?, layoutHit: TabDropKind?, placesBeside: Bool,
             sourceWindowID: String?, draggingAllOfSource: Bool, isGroup: Bool, besideEdge: TabDropEdge?) {
            window = windowID
            self.sidebarHit = switch sidebarHit {
            case .position: "position"
            case .intoGroup: "intoGroup"
            case .window, .merge, .beside: "window"
            case nil: nil
            }
            self.layoutHit = layoutHit.map { kind in
                if case let .newSplit(_, edge) = kind { PaneHit(splitEdge: WorkspaceDragWire.edgeName(edge)) } else { PaneHit(splitEdge: nil) }
            }
            self.placesBeside = placesBeside
            sourceWindow = sourceWindowID
            self.draggingAllOfSource = draggingAllOfSource
            self.isGroup = isGroup
            self.besideEdge = besideEdge.map(WorkspaceDragWire.edgeName)
        }
    }

    struct Target: Decodable { var kind: String, edge: String? }

    struct Outcome: Decodable {
        var outcome: String, id: String?, target: Target?

        func resolved(sidebarHit: WorkspaceDropTarget?, layoutHit: TabDropKind?, screenPoint: CGPoint) -> WorkspaceDragOutcome? {
            switch outcome {
            case "newWindow": return .newWindow(screenPoint: screenPoint)
            case "moveWindow": return .moveWindow(screenPoint: screenPoint)
            case "cancel": return .cancel
            case "window":
                guard let id, let target, let dropTarget = dropTarget(target, sidebarHit: sidebarHit, layoutHit: layoutHit) else { return nil }
                return .window(id: id, target: dropTarget)
            default: return nil
            }
        }

        private func dropTarget(_ target: Target, sidebarHit: WorkspaceDropTarget?, layoutHit: TabDropKind?) -> WorkspaceDropTarget? {
            switch target.kind {
            case "position", "intoGroup": sidebarHit
            case "window": .window
            case "merge": layoutHit.map(WorkspaceDropTarget.merge)
            case "beside": target.edge.flatMap(WorkspaceDragWire.edge(named:)).map(WorkspaceDropTarget.beside)
            default: nil
            }
        }
    }

    static func edgeName(_ edge: TabDropEdge) -> String {
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
}
