import AppKit
import CmuxSidebar
import Foundation

/// Keeps a table drag's source graph alive while AppKit materializes its native session.
///
/// ``NSTableView`` asks for pasteboard writers before it calls the table
/// controller's `draggingSession(_:willBeginAt:forRowIndexes:)` callback. The
/// representable can therefore be dismantled in that small interval. Retaining
/// the table and controller from the writer closes that gap without creating a
/// logical drag session early; the controller still owns terminal cleanup from
/// AppKit's `endedAt` callback.
@MainActor
final class SidebarWorkspaceDragPasteboardWriter: NSPasteboardItem, NSTableViewDelegate {
    private static let pasteboardType = NSPasteboard.PasteboardType(
        SidebarWorkspaceDragSession.pasteboardTypeIdentifier
    )
    let provisionalToken: ProvisionalDragWriterOwnership.Token
    private var workspaceId: UUID
    private var sessionId: UUID?

    // These are intentionally strong. AppKit retains the writer while it
    // builds (and, if successful, runs) the native session, so the source table
    // and its delegate cannot disappear between writer request and willBeginAt.
    private var sourceView: NSView?
    private var controller: SidebarWorkspaceTableController?
    private var actions: SidebarWorkspaceTableActions?
    private var provisionalSession: NSDraggingSession?
    private weak var previousTableDelegate: NSTableViewDelegate?

    init(
        workspaceId: UUID,
        sessionId: UUID?,
        sourceView: NSView,
        controller: SidebarWorkspaceTableController,
        provisionalToken: ProvisionalDragWriterOwnership.Token
    ) {
        self.workspaceId = workspaceId
        self.sessionId = sessionId
        self.sourceView = sourceView
        self.controller = controller
        self.provisionalToken = provisionalToken
        super.init()
        materializePayload()
    }

    @available(*, unavailable)
    required init(
        pasteboardPropertyList _: Any,
        ofType _: NSPasteboard.PasteboardType
    ) {
        fatalError("init(pasteboardPropertyList:ofType:) is not supported")
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        _ = pasteboard
        return [Self.pasteboardType]
    }

    /// Records the native generation associated with this writer request.
    ///
    /// ``NSTableView`` asks for this writer before `willBeginAt`; the controller
    /// writes the authoritative session payload directly to the native drag
    /// pasteboard at that boundary. Re-materializing here keeps the concrete
    /// item coherent for any AppKit path that reads it after promotion.
    func bind(to sessionId: UUID, workspaceId: UUID? = nil) {
        self.sessionId = sessionId
        if let workspaceId {
            self.workspaceId = workspaceId
        }
        // Keep the concrete NSPasteboardItem as the single writer
        // representation. The controller separately writes the same
        // generation to the session pasteboard at willBeginAt.
        materializePayload()
    }

    /// Captures the action bundle needed if the table is dismantled before
    /// AppKit promotes this writer.
    func configureProvisionalActions(_ actions: SidebarWorkspaceTableActions) {
        self.actions = actions
    }

    /// Moves the provisional native callbacks onto this writer, allowing the
    /// old controller/container graph to deallocate after SwiftUI dismantle.
    ///
    /// The writer remains retained by AppKit's pending/native item. If the old
    /// controller is gone, the fallback below still performs the exact
    /// token-scoped terminal transition.
    func installProvisionalDelegate() {
        guard let tableView = sourceView as? SidebarWorkspaceTableViewImpl else { return }
        previousTableDelegate = tableView.delegate
        tableView.delegate = self
        controller = nil
    }

    /// Releases the old controller while leaving this writer's source table
    /// available to the selected delegate for another pending writer.
    func releaseControllerGraphPreservingSource() {
        controller = nil
    }

    /// The concrete payload currently stored by this writer.
    var payloadValue: String {
        SidebarTabDragPayload(tabId: workspaceId, sessionId: sessionId).pasteboardValue
    }

    /// Workspace identity captured for this exact writer request.
    var workspaceIdForDrag: UUID { workspaceId }

    /// The source view that AppKit will use for the native session.
    ///
    /// The table controller reads this only while promoting a provisional
    /// writer to an active source after a view reconstruction.
    var sourceViewForDrag: NSView? { sourceView }

    /// Releases the source graph after this writer's native session terminates.
    func releaseSourceGraph() {
        if let tableView = sourceView as? SidebarWorkspaceTableViewImpl,
           tableView.delegate === self {
            tableView.delegate = previousTableDelegate
        }
        sourceView = nil
        controller = nil
        actions = nil
        provisionalSession = nil
        previousTableDelegate = nil
    }

    override func responds(to selector: Selector) -> Bool {
        super.responds(to: selector)
            || previousTableDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector) -> Any? {
        previousTableDelegate
            ?? super.forwardingTarget(for: selector)
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        guard controller == nil else {
            controller?.tableView(
                tableView,
                draggingSession: session,
                willBeginAt: screenPoint,
                forRowIndexes: rowIndexes
            )
            return
        }
        guard provisionalSession == nil || provisionalSession === session else { return }
        provisionalSession = session
        actions?.beginWorkspaceDrag(workspaceId)
        if let sessionId = actions?.nativeWorkspaceDragLifecycle?.currentSessionId() {
            bind(to: sessionId)
            session.draggingPasteboard.setString(
                payloadValue,
                forType: Self.pasteboardType
            )
        }
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard controller == nil else {
            controller?.tableView(
                tableView,
                draggingSession: session,
                endedAt: screenPoint,
                operation: operation
            )
            return
        }
        guard provisionalSession === session else { return }
        if let lifecycle = actions?.nativeWorkspaceDragLifecycle,
           let boundSessionId = sessionId,
           lifecycle.currentSessionId() == boundSessionId {
            let capabilityValue = SidebarTabDragPayload(
                tabId: workspaceId,
                sessionId: boundSessionId
            ).pasteboardValue
            lifecycle.finish(boundSessionId, capabilityValue)
        } else if actions?.nativeWorkspaceDragLifecycle == nil,
                  sessionId == nil {
            actions?.endWorkspaceDrag()
        }
        releaseSourceGraph()
    }

    /// Keeps the concrete item populated for the pre-session AppKit write.
    private func materializePayload() {
        _ = setString(
            payloadValue,
            forType: Self.pasteboardType
        )
    }
}
