import AppKit
import CmuxFileSearch

// Dragging a result into a pane opens a file preview, like the Files tree.
// The ownership rules match FileExplorerPanelView.Coordinator's outline drag:
// the pasteboard writer retains this panel until AppKit's terminal callback,
// and the coordinator tracks the promoted source so a rebuilt view can
// reclaim a drag whose endedAt was lost.
extension FileSearchPanelView {
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === resultsView,
              coordinator.store.provider is LocalFileExplorerProvider,
              let file = file(atRow: row) else { return nil }
        let writer = FilePreviewDragPasteboardWriter(
            filePath: file.path,
            displayTitle: (file.relativePath as NSString).lastPathComponent,
            nativeSourceView: tableView,
            nativeSourceOwner: self,
            provisionalToken: pendingPreviewDrag.makeToken()
        )
        resultsView.pendingNativeDragWriter = writer
        resultsView.pendingNativeDragTokenID = writer.provisionalToken?.id
        pendingPreviewDrag.register(writer)
        return writer
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        guard tableView === resultsView else { return }
        if let previousSession = resultsView.activeNativeDragSession, previousSession === session {
            return
        }
        if coordinator.isTrackingNativeDrag(session) {
            return
        }
        // A distinct begin is a native boundary, including when the previous
        // source belonged to a view replaced by SwiftUI reconstruction.
        _ = coordinator.reclaimTrackedNativeDrag()
        let fallbackWriter = resultsView.pendingNativeDragWriter
        var promotedWriters = pendingPreviewDrag.writers(for: tableView)
        if let fallbackWriter, !promotedWriters.contains(where: { $0 === fallbackWriter }) {
            promotedWriters.append(fallbackWriter)
        }
        pendingPreviewDrag.finishPending(preserving: promotedWriters)
        let resultsView = self.resultsView
        coordinator.supersedeNativeDragIfNeeded(
            previousSession: resultsView.activeNativeDragSession,
            newSession: session,
            finishPrevious: {
                let pasteboard = resultsView.activeNativeDragSession?.draggingPasteboard ?? session.draggingPasteboard
                for ownership in resultsView.activeNativeDragOwnerships {
                    ownership.finish(from: pasteboard)
                }
            },
            clearPrevious: {
                resultsView.activeNativeDragWriter?.releaseSourceGraph()
                resultsView.activeNativeDragWriter = nil
                resultsView.activeNativeDragDelegateMarker = nil
                resultsView.activeNativeDragOwnerships = []
                resultsView.activeNativeDragSession = nil
            }
        )
        // The ordered list mirrors AppKit's pasteboard item order; its first
        // writer is the canonical source identity.
        let promotedWriter = promotedWriters.first ?? fallbackWriter
        let promotedOwnerships = pendingPreviewDrag.promote(writers: promotedWriters)
        promotedWriter?.materializeRegisteredPayload(to: session.draggingPasteboard)
        let ownerships = promotedOwnerships.isEmpty
            ? (promotedWriter?.nativeDragOwnership()).map { [$0] } ?? []
            : promotedOwnerships
        // The writer retains this panel through the terminal callback; the
        // table keeps only a weak marker to avoid a retain cycle.
        resultsView.activeNativeDragDelegateMarker = self
        resultsView.activeNativeDragWriter = promotedWriter
        resultsView.activeNativeDragOwnerships = ownerships
        resultsView.pendingNativeDragWriter = nil
        resultsView.pendingNativeDragTokenID = nil
        resultsView.activeNativeDragSession = session
        coordinator.trackNativeDrag(sourceView: resultsView, session: session, writer: promotedWriter, ownerships: ownerships)
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard tableView === resultsView, resultsView.activeNativeDragSession === session else { return }
        if resultsView.activeNativeDragOwnerships.isEmpty {
            // This is the matching generation, so the fallback cannot parse
            // a newer session's shared pasteboard.
            FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: session)
        } else {
            for ownership in resultsView.activeNativeDragOwnerships {
                ownership.finish(from: session.draggingPasteboard)
            }
        }
        clearActiveDrag()
        coordinator.forgetTrackedNativeDrag(matching: session)
    }

    /// Reclaims a drag whose terminal callback was lost, at the next pointer
    /// gesture. AppKit cannot deliver that mouseDown while the old drag loop
    /// is live, so releasing the writer's retain here is safe.
    func prepareForNativeDragBoundary() {
        if coordinator.reclaimTrackedNativeDrag() {
            pendingPreviewDrag.finishPending()
            resultsView.pendingNativeDragWriter = nil
            resultsView.pendingNativeDragTokenID = nil
            return
        }
        guard let session = resultsView.activeNativeDragSession else {
            resultsView.activeNativeDragDelegateMarker = nil
            pendingPreviewDrag.finishPending()
            if let tokenID = resultsView.pendingNativeDragTokenID {
                pendingPreviewDrag.remove(tokenID: tokenID)
            }
            resultsView.pendingNativeDragWriter = nil
            resultsView.pendingNativeDragTokenID = nil
            resultsView.activeNativeDragOwnership = nil
            return
        }
        for ownership in resultsView.activeNativeDragOwnerships {
            ownership.finish(from: session.draggingPasteboard)
        }
        pendingPreviewDrag.finishPending()
        resultsView.pendingNativeDragWriter = nil
        resultsView.pendingNativeDragTokenID = nil
        clearActiveDrag()
        coordinator.forgetTrackedNativeDrag(matching: session)
    }

    /// Drops stale drag markers when the view is dismantled with no drag running.
    func clearNativeDragMarkersIfIdle() {
        guard resultsView.activeNativeDragSession == nil else { return }
        for ownership in resultsView.activeNativeDragOwnerships {
            ownership.revokeRouting()
        }
        clearActiveDrag()
    }

    func previewWriterDidDeallocate(tokenID: UUID) {
        guard resultsView.pendingNativeDragTokenID == tokenID else { return }
        resultsView.pendingNativeDragWriter = nil
        resultsView.pendingNativeDragTokenID = nil
    }

    private func clearActiveDrag() {
        resultsView.activeNativeDragDelegateMarker = nil
        resultsView.activeNativeDragWriter?.releaseSourceGraph()
        resultsView.activeNativeDragWriter = nil
        resultsView.activeNativeDragOwnerships = []
        resultsView.activeNativeDragSession = nil
    }
}
