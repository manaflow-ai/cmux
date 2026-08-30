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
final class SidebarWorkspaceDragPasteboardWriter: NSPasteboardItem {
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
        sourceView = nil
        controller = nil
    }

    /// Keeps the concrete item populated for the pre-session AppKit write.
    private func materializePayload() {
        _ = setString(
            payloadValue,
            forType: Self.pasteboardType
        )
    }
}
