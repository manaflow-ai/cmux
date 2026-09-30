import AppKit

/// Native drag sources for the Files outline.
///
/// File rows drag through ``FilePreviewDragPasteboardWriter`` so cmux panes
/// can open them as previews; that path carries the native-session ownership
/// fencing below. Folders drag as file URLs and remote rows as path text.
extension FileExplorerPanelView.Coordinator {
    /// Applies the shared native-generation fence used by both file
    /// preview drag sources. A distinct `willBeginAt` session is an
    /// authoritative boundary and replaces the prior owner.
    func supersedeNativeDragIfNeeded(
        previousSession: NSDraggingSession?,
        newSession: NSDraggingSession,
        finishPrevious: () -> Void,
        clearPrevious: () -> Void
    ) {
        guard let previousSession, previousSession !== newSession else { return }
        // A distinct `willBeginAt` callback is itself an AppKit native
        // boundary. Sequence numbers are useful for terminal fencing but
        // cannot reject this promotion because the OS may reuse them.
        finishPrevious()
        clearPrevious()
    }

    func trackNativeDrag(
        sourceView: NSView,
        session: NSDraggingSession,
        writer: FilePreviewDragPasteboardWriter?,
        ownerships: [FilePreviewNativeDragOwnership]
    ) {
        activeNativeDragSourceView = sourceView
        activeNativeDragWriter = writer
        activeNativeDragSession = session
        activeNativeDragOwnerships = ownerships
    }

    func clearTrackedSourceState() {
        if let outlineView = activeNativeDragSourceView as? FileExplorerNSOutlineView {
            outlineView.activeNativeDragDelegateMarker = nil
            outlineView.activeNativeDragWriter?.releaseSourceGraph()
            outlineView.activeNativeDragWriter = nil
            outlineView.activeNativeDragOwnerships = []
            outlineView.activeNativeDragSession = nil
        } else if let searchResultsView = activeNativeDragSourceView as? FileExplorerSearchResultsTableView {
            searchResultsView.activeNativeDragDelegateMarker = nil
            searchResultsView.activeNativeDragWriter?.releaseSourceGraph()
            searchResultsView.activeNativeDragWriter = nil
            searchResultsView.activeNativeDragOwnerships = []
            searchResultsView.activeNativeDragSession = nil
        }
    }

    /// Reclaims the promoted source even when its original view is no
    /// longer the coordinator's current representable.
    @discardableResult
    func reclaimTrackedNativeDrag() -> Bool {
        guard let session = activeNativeDragSession else { return false }
        if activeNativeDragOwnerships.isEmpty {
            FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: session)
        } else {
            for ownership in activeNativeDragOwnerships {
                ownership.finish(from: session.draggingPasteboard)
            }
        }
        let writer = activeNativeDragWriter
        clearTrackedSourceState()
        writer?.releaseSourceGraph()
        activeNativeDragSourceView = nil
        activeNativeDragWriter = nil
        activeNativeDragSession = nil
        activeNativeDragOwnerships = []
        return true
    }

    func isTrackingNativeDrag(_ session: NSDraggingSession) -> Bool {
        activeNativeDragSession === session
    }

    func forgetTrackedNativeDrag(matching session: NSDraggingSession) {
        guard activeNativeDragSession === session else { return }
        activeNativeDragSourceView = nil
        activeNativeDragWriter = nil
        activeNativeDragSession = nil
        activeNativeDragOwnerships = []
    }

    func previewWriterDidDeallocate(tokenID: UUID) {
        guard let outlineView = outlineView as? FileExplorerNSOutlineView,
              outlineView.pendingNativeDragTokenID == tokenID else { return }
        outlineView.pendingNativeDragWriter = nil
        outlineView.pendingNativeDragTokenID = nil
    }

    // MARK: - Drag-to-Preview

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? FileExplorerNode else { return nil }
        guard store.provider is LocalFileExplorerProvider else {
            // Remote rows drag as their remote path text, e.g. into a terminal
            // attached to the same host.
            return node.path as NSString
        }
        if node.isDirectory {
            // Folders drag as plain file URLs: Finder, terminals and other
            // apps accept them; cmux file previews only take files.
            return URL(fileURLWithPath: node.path, isDirectory: true) as NSURL
        }
        let writer = FilePreviewDragPasteboardWriter(
            filePath: node.path,
            displayTitle: node.name,
            nativeSourceView: outlineView,
            // Retain the exact container/delegate graph through a
            // representable rebuild; the coordinator's container edge is
            // intentionally weak.
            nativeSourceOwner: containerView ?? outlineView,
            provisionalToken: pendingPreviewDrag.makeToken()
        )
        if let outlineView = outlineView as? FileExplorerNSOutlineView {
            outlineView.pendingNativeDragWriter = writer
            pendingPreviewDrag.register(writer)
            outlineView.pendingNativeDragTokenID = writer.provisionalToken?.id
        }
        return writer
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItems draggedItems: [Any]
    ) {
        _ = screenPoint
        _ = draggedItems
        if let outlineView = outlineView as? FileExplorerNSOutlineView {
            if outlineView.activeNativeDragSession === session {
                return
            }
            if activeNativeDragSession === session {
                return
            }
            // A distinct begin is a native boundary, even when the prior
            // source belonged to a rebuilt outline view.
            _ = reclaimTrackedNativeDrag()
            let fallbackWriter = outlineView.pendingNativeDragWriter
            var promotedWriters = pendingPreviewDrag.writers(for: outlineView)
            if let fallbackWriter,
               !promotedWriters.contains(where: { $0 === fallbackWriter }) {
                promotedWriters.append(fallbackWriter)
            }
            pendingPreviewDrag.finishPending(preserving: promotedWriters)
            supersedeNativeDragIfNeeded(
                previousSession: outlineView.activeNativeDragSession,
                newSession: session,
                finishPrevious: {
                    let pasteboard = outlineView.activeNativeDragSession?.draggingPasteboard
                        ?? session.draggingPasteboard
                    for ownership in outlineView.activeNativeDragOwnerships {
                        ownership.finish(from: pasteboard)
                    }
                },
                clearPrevious: {
                    outlineView.activeNativeDragWriter?.releaseSourceGraph()
                    outlineView.activeNativeDragWriter = nil
                    outlineView.activeNativeDragDelegateMarker = nil
                    outlineView.activeNativeDragOwnerships = []
                    outlineView.activeNativeDragOwnership = nil
                    outlineView.activeNativeDragSession = nil
                }
            )
            // The ordered list mirrors AppKit's pasteboard item order; use
            // its first writer as the canonical source identity.
            let promotedWriter = promotedWriters.first ?? fallbackWriter
            let promotedOwnerships = pendingPreviewDrag.promote(writers: promotedWriters)
            promotedWriter?.materializeRegisteredPayload(to: session.draggingPasteboard)
            let ownerships = promotedOwnerships.isEmpty
                ? (promotedWriter?.nativeDragOwnership()).map { [$0] } ?? []
                : promotedOwnerships
            outlineView.activeNativeDragDelegateMarker = self
            outlineView.activeNativeDragSession = session
            outlineView.activeNativeDragWriter = promotedWriter
            outlineView.activeNativeDragOwnerships = ownerships
            outlineView.pendingNativeDragWriter = nil
            outlineView.pendingNativeDragTokenID = nil
            trackNativeDrag(
                sourceView: outlineView,
                session: session,
                writer: promotedWriter,
                ownerships: ownerships
            )
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard let outlineView = outlineView as? FileExplorerNSOutlineView,
              outlineView.activeNativeDragSession === session else {
            // The delegate may have been rebuilt between writer creation
            // and the terminal callback. Use this session's own pasteboard
            // for idempotent capability cleanup; never inspect the
            // process-wide board here.
            FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: session)
            return
        }
        if !outlineView.activeNativeDragOwnerships.isEmpty {
            for ownership in outlineView.activeNativeDragOwnerships {
                ownership.finish(from: session.draggingPasteboard)
            }
        } else {
            // The matching session identity proves this is not a stale
            // callback. Keep a compatibility fallback for an AppKit path
            // that released the plain writer before promotion.
            FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: session)
        }
        outlineView.activeNativeDragDelegateMarker = nil
        outlineView.activeNativeDragWriter?.releaseSourceGraph()
        outlineView.activeNativeDragWriter = nil
        outlineView.activeNativeDragOwnerships = []
        outlineView.activeNativeDragOwnership = nil
        outlineView.activeNativeDragSession = nil
        forgetTrackedNativeDrag(matching: session)
    }

    /// Reclaims an outline drag at the next pointer boundary when AppKit
    /// omitted its native terminal callback during reconstruction. The
    /// exact outline argument matters because ``Coordinator.outlineView``
    /// may already point at a newly built view.
    func prepareForNativeDragBoundary(on outlineView: NSOutlineView) {
        guard let outlineView = outlineView as? FileExplorerNSOutlineView else { return }
        if reclaimTrackedNativeDrag() {
            // The tracked source may be an older outline retained by the
            // writer. Clear only this view's pending request; its active
            // state, if any, belongs to a separate generation.
            pendingPreviewDrag.finishPending()
            outlineView.pendingNativeDragWriter = nil
            outlineView.pendingNativeDragTokenID = nil
            return
        }
        guard let session = outlineView.activeNativeDragSession else {
            outlineView.activeNativeDragDelegateMarker = nil
            pendingPreviewDrag.finishPending()
            outlineView.pendingNativeDragWriter = nil
            if let tokenID = outlineView.pendingNativeDragTokenID {
                pendingPreviewDrag.remove(tokenID: tokenID)
            }
            outlineView.pendingNativeDragTokenID = nil
            outlineView.activeNativeDragOwnership = nil
            return
        }
        for ownership in outlineView.activeNativeDragOwnerships {
            ownership.finish(from: session.draggingPasteboard)
        }
        pendingPreviewDrag.finishPending()
        outlineView.activeNativeDragDelegateMarker = nil
        outlineView.pendingNativeDragWriter = nil
        outlineView.pendingNativeDragTokenID = nil
        outlineView.activeNativeDragWriter?.releaseSourceGraph()
        outlineView.activeNativeDragWriter = nil
        outlineView.activeNativeDragOwnerships = []
        outlineView.activeNativeDragOwnership = nil
        outlineView.activeNativeDragSession = nil
    }
}
