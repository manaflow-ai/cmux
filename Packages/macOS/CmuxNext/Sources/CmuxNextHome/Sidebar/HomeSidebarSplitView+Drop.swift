public import AppKit

/// A file or picture dragged over Home's conversation list goes to the shown conversation, as a drop
/// on its transcript does: the whole Home pane is one drop target (Lawrence 2026-10-20: "I want people
/// to drag images into Chief properly"). The list registers no drag types, so its drags reach this
/// split view; the conversation's own view decides, takes the drop and draws the highlight. The New
/// Message page takes no attachments (its view has no preparer), so it takes no drop.
extension HomeSidebarSplitView {
    /// The split registers the composer's drag types once it is in a window.
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if registeredDraggedTypes.isEmpty { registerForDraggedTypes(HomeNativeTranscriptView.attachmentDragTypes) }
    }

    /// The shown conversation's view in the chat column: visible and taking attachments.
    private var dropTarget: HomeNativeTranscriptView? {
        var stack: [NSView] = [chatColumn.content]
        while let next = stack.popLast() {
            if next.isHidden { continue }
            if let view = next as? HomeNativeTranscriptView { if view.canAttach { return view } else { continue } }
            stack.append(contentsOf: next.subviews)
        }
        return nil
    }

    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTarget?.draggingEntered(sender) ?? []
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTarget?.draggingUpdated(sender) ?? []
    }

    // NSView has no `draggingExited:`/`draggingEnded:` of its own: no super call.
    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropTarget?.draggingExited(sender)
    }

    override public func draggingEnded(_ sender: any NSDraggingInfo) {
        dropTarget?.draggingEnded(sender)
    }

    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropTarget?.performDragOperation(sender) ?? false
    }
}
