import AppKit
import Bonsplit
import UniformTypeIdentifiers

/// Native drag for a mode bar tab carried out of the bar toward a pane.
/// Reordering inside the bar never starts a drag session
/// (`RightSidebarModeBarDragController`); this only runs once the tab leaves
/// the bar. Same shape as a Vault row's drag (`SessionDragCoordinator`): the
/// pane destinations resolve the tool from Bonsplit's process-local capability,
/// and the in-process custom UTI (declared in `Resources/Info.plist` under
/// `UTExportedTypeDeclarations`) carries the mode's raw value.
enum RightSidebarModeDragPayload {
    static let typeIdentifier = "com.cmux.right-sidebar-mode-reorder"
    static let dropContentType = UTType(exportedAs: typeIdentifier)

    /// Starts the native drag from `sourceView`, whose coordinates `frame` is
    /// in. Returns nil, leaving nothing registered, when the mode cannot open
    /// as a pane or AppKit rejects the capability.
    @MainActor
    static func beginPaneDrag(
        mode: RightSidebarMode,
        from sourceView: NSView,
        event: NSEvent,
        frame: NSRect,
        image: NSImage,
        onEnd: @escaping @MainActor () -> Void
    ) -> RightSidebarModePaneDragSource? {
        guard frame.width > 0, frame.height > 0,
              let registry = AppDelegate.shared?.tabDragTransferRegistry,
              let registration = RightSidebarToolDragPayload(mode: mode).register(with: registry) else { return nil }
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        guard registration.write(to: pasteboard) else {
            registry.end(registration)
            AppDelegate.shared?.liveTabDragCapabilityResolver.invalidate()
            return nil
        }
        registration.pasteboardItem.setData(
            Data(mode.rawValue.utf8),
            forType: NSPasteboard.PasteboardType(typeIdentifier)
        )
        let source = RightSidebarModePaneDragSource(registration: registration, registry: registry, onEnd: onEnd)
        let item = NSDraggingItem(pasteboardWriter: registration.pasteboardItem)
        item.setDraggingFrame(frame, contents: image)
        sourceView.beginDraggingSession(with: [item], event: event, source: source)
        source.bind(sourceView: sourceView)
        return source
    }
}

/// Retained native source whose terminal callback ends a carried-out tab drag.
@MainActor
final class RightSidebarModePaneDragSource: NSObject, NSDraggingSource {
    private let registration: TabDragTransferRegistration
    private let registry: TabDragTransferRegistry
    private let onEnd: @MainActor () -> Void
    private var isFinished = false
    // AppKit's drag loop can outlive the SwiftUI view that started it.
    private var sourceView: NSView?

    init(
        registration: TabDragTransferRegistration,
        registry: TabDragTransferRegistry,
        onEnd: @escaping @MainActor () -> Void
    ) {
        self.registration = registration
        self.registry = registry
        self.onEnd = onEnd
    }

    /// Retains the source view until AppKit delivers `endedAt`.
    func bind(sourceView: NSView) {
        guard !isFinished else { return }
        self.sourceView = sourceView
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        finish()
        // The drag pasteboard keeps this capability's type after the session
        // ends; clear only this registration's value.
        registration.clearResidualCapability(from: session.draggingPasteboard)
    }

    /// Ends the drag. Also called when a newer tab drag starts, which proves
    /// AppKit has left this one's drag loop even if `endedAt` never came.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        registry.end(registration)
        sourceView = nil
        onEnd()
    }
}
