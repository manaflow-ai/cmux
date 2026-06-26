import AppKit

/// Tracks whether an interactive window-geometry resize is in progress so the
/// terminal portal can flush the latest visible frame during a drag instead of
/// rescheduling behind the drag stream. Two signals feed
/// ``isInteractiveGeometryResizeActive``: an explicit begin/end depth counter
/// (sidebar/split drags that announce themselves through
/// ``beginInteractiveGeometryResize()`` / ``endInteractiveGeometryResize()``),
/// and live detection of a split-divider pointer drag derived from the current
/// `NSEvent`.
///
/// This was pulled out of the `TerminalWindowPortalRegistry` namespace-enum into
/// a real owned `@MainActor` instance so the drag-tracking state has a single
/// concrete owner. The `NSEvent`/`NSApp`/`NSWindow` and
/// `WindowTerminalHostView.hasSplitDivider` coupling stays app-side here.
/// Behavior is a byte-faithful lift of the former static members.
@MainActor
final class InteractiveGeometryResizeTracker {
#if DEBUG
    var isPointerDragActiveForTesting = false
#endif

    private var interactiveGeometryResizeCount = 0
    private var activeSplitDividerDragWindowId: ObjectIdentifier?
    private var activeSplitDividerDragEventNumber: Int?

    var isInteractiveGeometryResizeActive: Bool {
#if DEBUG
        if isPointerDragActiveForTesting { return true }
#endif
        if interactiveGeometryResizeCount > 0 { return true }
        return isCurrentEventSplitDividerDrag()
    }

    func beginInteractiveGeometryResize() {
        interactiveGeometryResizeCount += 1
    }

    func endInteractiveGeometryResize() {
        interactiveGeometryResizeCount = max(0, interactiveGeometryResizeCount - 1)
    }

    func noteSplitDividerInteraction(in window: NSWindow?, event: NSEvent?) {
        guard let window, let event else { return }
        guard (NSEvent.pressedMouseButtons & 1) != 0 else { return }

        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            activeSplitDividerDragWindowId = ObjectIdentifier(window)
            activeSplitDividerDragEventNumber = event.eventNumber
        default:
            break
        }
    }

    private func isCurrentEventSplitDividerDrag() -> Bool {
        let isLeftButtonDown = (NSEvent.pressedMouseButtons & 1) != 0
        guard isLeftButtonDown else {
            clearActiveSplitDividerDrag()
            return false
        }

        guard let event = NSApp.currentEvent else { return false }

        switch event.type {
        case .leftMouseUp:
            clearActiveSplitDividerDrag()
            return false
        case .leftMouseDown, .leftMouseDragged:
            break
        default:
            return false
        }

        if let activeSplitDividerDragWindowId, let activeSplitDividerDragEventNumber {
            let hasActiveWindow = NSApp.windows.contains { ObjectIdentifier($0) == activeSplitDividerDragWindowId }
            if hasActiveWindow, event.eventNumber == activeSplitDividerDragEventNumber {
                return true
            }
            clearActiveSplitDividerDrag()
        }

        guard event.type == .leftMouseDown else { return false }

        let candidateWindows = currentSplitDividerDragCandidateWindows(for: event)
        let mouseLocation = NSEvent.mouseLocation
        for window in candidateWindows {
            if WindowTerminalHostView.hasSplitDivider(atScreenPoint: mouseLocation, in: window) {
                activeSplitDividerDragWindowId = ObjectIdentifier(window)
                activeSplitDividerDragEventNumber = event.eventNumber
                return true
            }
        }

        return false
    }

    private func clearActiveSplitDividerDrag() {
        activeSplitDividerDragWindowId = nil
        activeSplitDividerDragEventNumber = nil
    }

    private func currentSplitDividerDragCandidateWindows(for event: NSEvent) -> [NSWindow] {
        var candidateWindows: [NSWindow] = []
        if let eventWindow = event.window {
            candidateWindows.append(eventWindow)
        }
        if let keyWindow = NSApp.keyWindow, !candidateWindows.contains(where: { $0 === keyWindow }) {
            candidateWindows.append(keyWindow)
        }
        if let mainWindow = NSApp.mainWindow, !candidateWindows.contains(where: { $0 === mainWindow }) {
            candidateWindows.append(mainWindow)
        }
        return candidateWindows
    }
}
