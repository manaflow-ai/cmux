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
    nonisolated static let didDeallocateNotification = Notification.Name(
        "cmux.sidebarWorkspaceDragPasteboardWriterDidDeallocate"
    )
    nonisolated static let deallocationTokenKey = "token"
    private static let pasteboardType = NSPasteboard.PasteboardType(
        SidebarWorkspaceDragSession.pasteboardTypeIdentifier
    )
    let provisionalToken = UUID()
    private var workspaceId: UUID
    private var sessionId: UUID?

    // These are intentionally strong. AppKit retains the writer while it
    // builds (and, if successful, runs) the native session, so the source table
    // and its delegate cannot disappear between writer request and willBeginAt.
    private let sourceView: NSView
    private let controller: SidebarWorkspaceTableController

    init(
        workspaceId: UUID,
        sessionId: UUID?,
        sourceView: NSView,
        controller: SidebarWorkspaceTableController
    ) {
        self.workspaceId = workspaceId
        self.sessionId = sessionId
        self.sourceView = sourceView
        self.controller = controller
        super.init()
    }

    @available(*, unavailable)
    required init(
        pasteboardPropertyList propertyList: Any,
        ofType type: NSPasteboard.PasteboardType
    ) {
        fatalError("init(pasteboardPropertyList:ofType:) is not supported")
    }

    deinit {
        // The writer is AppKit's provisional ownership token. Its deallocation
        // proves that no native session callback can still arrive for this
        // writer, so the controller can release an abandoned teardown hold.
        NotificationCenter.default.post(
            name: Self.didDeallocateNotification,
            object: nil,
            userInfo: [Self.deallocationTokenKey: provisionalToken]
        )
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        _ = pasteboard
        return [Self.pasteboardType]
    }

    /// Binds the writer to the native generation AppKit created for it.
    ///
    /// ``NSTableView`` asks for this writer before `willBeginAt`, so the initial
    /// representation is necessarily legacy-shaped. Updating the writer as
    /// soon as the session exists keeps a later lazy pasteboard materialization
    /// from replacing the live token with that provisional value. The callback's
    /// row identity is authoritative even when an older provisional writer is
    /// still retained by AppKit.
    func bind(to sessionId: UUID, workspaceId: UUID? = nil) {
        self.sessionId = sessionId
        if let workspaceId {
            self.workspaceId = workspaceId
        }
    }

    /// Workspace identity captured for this exact writer request.
    var workspaceIdForDrag: UUID { workspaceId }

    /// The source view that AppKit will use for the native session.
    ///
    /// The table controller reads this only while promoting a provisional
    /// writer to an active source after a view reconstruction.
    var sourceViewForDrag: NSView { sourceView }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard type == Self.pasteboardType else { return nil }
        return SidebarTabDragPayload(tabId: workspaceId, sessionId: sessionId).pasteboardValue
    }
}
