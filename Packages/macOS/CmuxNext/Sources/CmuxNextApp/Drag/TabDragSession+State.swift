import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs
import QuartzCore

// MARK: - Drag state

extension TabDragSession {
    enum Item {
        case tab(String)
        case group(CmuxNextTabs.TabGroupID, members: [String])
        /// Sidebar workspaces (a selection, or `group`'s members).
        case workspaces([String], group: String?)
    }

    struct Source {
        var item: Item
        /// Nil for workspace items (strips and panes take tabs only).
        var payload: TabDragPayload?
        weak var pane: PaneController?
        weak var window: WindowController?
        var screenFrame: CGRect
        var grabOffset: CGPoint
        /// Dragged tab's top-left relative to its window's top-left (x right, y down).
        var tabOffset: CGPoint
        var windowSize: CGSize
        var context: TabDragContext
    }

    enum Presentation: Equatable {
        case none
        case card
        case inline(CGRect)
    }

    struct Winner {
        var provider: any TabDropTargetProviding
        var proposal: TabDropProposal
        weak var window: WindowController?
    }

    final class Drag {
        let source: Source
        let lifecycle: TabDragLifecycle
        let ghost: TabDragGhostPanel
        var motion: TabDragGhostMotion
        var point: CGPoint
        var winner: Winner?
        var outcome: TabDragOutcome = .cancel
        var presentation: Presentation = .none
        var monitor: Any?
        var link: CADisplayLink?
        var lastTime: CFTimeInterval?
        /// Every surface that answered during this drag, told once at the end.
        var touched: [ObjectIdentifier: any TabDropTargetProviding] = [:]
        var adapters: [ObjectIdentifier: (sidebar: SidebarTabDropTarget, layout: LayoutTabDropTarget)] = [:]
        /// Workspace items: the current outcome and the sidebar lit for it.
        var workspaceOutcome: WorkspaceDragOutcome = .cancel
        var workspaceHighlight: CGRect?
        weak var workspaceSidebar: SidebarTabDropTarget?

        init(source: Source, lifecycle: TabDragLifecycle, ghost: TabDragGhostPanel, motion: TabDragGhostMotion, point: CGPoint) {
            self.source = source
            self.lifecycle = lifecycle
            self.ghost = ghost
            self.motion = motion
            self.point = point
        }
    }
}

extension TabDropEdge {
    var paneEdge: PaneEdge {
        switch self {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        }
    }
}
