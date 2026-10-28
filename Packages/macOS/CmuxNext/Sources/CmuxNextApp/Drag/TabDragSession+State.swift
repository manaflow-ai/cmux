import AppKit
import CmuxNextWakeups
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
        var work = TabDragWork()
        /// Drag events moved the pointer since the last hit test; the next frame runs it (`move`).
        var pointerMoved = false
        /// The point where the last frame's autoscroll found nothing to scroll; a frame at the
        /// same point skips the check.
        var autoscrollIdleAt: CGPoint?
        /// The hit test's resolver context, kept until what it read changes (`cachedContext`).
        var keptContext: (context: TabDragContext, changed: TabDragChangeFlag, owners: [ObjectIdentifier?])?
        let windowOrder = TabDragWindowOrder()
        let lifecycle: TabDragLifecycle
        let ghost: TabDragGhostPanel
        var motion: TabDragGhostMotion
        /// The motion the ghost last rendered; a frame renders only when it differs (`tick`).
        var renderedMotion: TabDragGhostMotion?
        var point: CGPoint
        /// Pointer velocity in points per second, from `samplePointer`.
        var pointerVelocity = CGVector.zero
        var lastPointerSample: (point: CGPoint, time: CFTimeInterval)?
        var winner: Winner?
        var outcome: TabDragOutcome = .cancel
        /// What the pointer previews now; `outcome` is its outcome.
        var resolution = TabDropResolution(preview: .none, outcome: .cancel)
        /// The layout whose overlay draws the outline now (pane zones, and
        /// strip slots of that window); nil over the sidebar or outside.
        var outlinedLayout: LayoutTabDropTarget?
        /// Why the window under the pointer offers no target (incognito
        /// crossing); nil when it does.
        var noTargetReason: String?
        var presentation: Presentation = .none
        var monitor: Any?
        var link: FrameClient?
        /// Every surface that answered during this drag, told once at the end.
        var touched: [ObjectIdentifier: any TabDropTargetProviding] = [:]
        var adapters: [ObjectIdentifier: (sidebar: SidebarTabDropTarget, layout: LayoutTabDropTarget)] = [:]
        /// Workspace items: the current outcome and the sidebar lit for it.
        var workspaceOutcome: WorkspaceDragOutcome = .cancel
        var workspaceHighlight: CGRect?
        /// Option was held at the drop: file the tabs away, no view change.
        var filesAway = false
        /// The dragged tabs, focus first (read at the drop, before a move
        /// can close the source pane).
        var revealTabs: [String] = []
        /// The workspace the tabs landed in, for a reveal that shows it.
        var landedWorkspaceID: String?
        /// The landing was shown at the drop, from the store's intent, before the daemon's echo
        /// (tab-move-tearing); `revealedFrom` is the workspace the window showed then, shown again
        /// when the daemon refuses the move.
        var revealedEarly = false
        var revealedFrom: String?
        weak var workspaceSidebar: SidebarTabDropTarget?
        /// The layout previewing a merge of the dragged workspace.
        weak var workspaceLayout: LayoutTabDropTarget?

        init(source: Source, lifecycle: TabDragLifecycle, ghost: TabDragGhostPanel, motion: TabDragGhostMotion, point: CGPoint) {
            self.source = source
            self.lifecycle = lifecycle
            self.ghost = ghost
            self.motion = motion
            self.point = point
        }

        /// Records a pointer position for the release velocity.
        func samplePointer(_ point: CGPoint, at time: CFTimeInterval) {
            if let last = lastPointerSample, time > last.time {
                let dt = time - last.time
                let instant = CGVector(dx: (point.x - last.point.x) / dt, dy: (point.y - last.point.y) / dt)
                pointerVelocity = CGVector(dx: pointerVelocity.dx * 0.4 + instant.dx * 0.6, dy: pointerVelocity.dy * 0.4 + instant.dy * 0.6)
            }
            lastPointerSample = (point, time)
        }

        /// The velocity to carry into a release at `time`: zero when the
        /// pointer had stopped (no sample in the last 50 ms).
        func releaseVelocity(at time: CFTimeInterval) -> CGVector {
            guard let last = lastPointerSample, time - last.time <= 0.05 else { return .zero }
            return pointerVelocity
        }
    }
}
