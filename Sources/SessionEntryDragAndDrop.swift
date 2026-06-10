import AppKit
import Bonsplit
import CMUXAgentVault
import SQLite3
import SwiftUI
import UniformTypeIdentifiers


// MARK: - Session entry drag and drop
/// Mirrors `Bonsplit.TabItem`'s Codable shape so we can produce a JSON payload
/// that bonsplit's external-drop path will decode and accept.
private struct MirrorTabItem: Codable {
    let id: UUID
    let title: String
    let hasCustomTitle: Bool
    let icon: String?
    let iconImageData: Data?
    let kind: String?
    let isDirty: Bool
    let showsNotificationBadge: Bool
    let isLoading: Bool
    let isAudioMuted: Bool
    let isPinned: Bool
}

/// Mirrors `Bonsplit.TabTransferData` exactly.
private struct MirrorTabTransferData: Codable {
    let tab: MirrorTabItem
    let sourcePaneId: UUID
    let sourceProcessId: Int32
}

/// Build the encoded payload bonsplit's external-drop decoder accepts.
private func sessionTabTransferData(for entry: SessionEntry, dragId: UUID) -> Data? {
    let mirror = MirrorTabTransferData(
        tab: MirrorTabItem(
            id: dragId,
            title: entry.displayTitle,
            hasCustomTitle: false,
            icon: "terminal.fill",
            iconImageData: nil,
            kind: "terminal",
            isDirty: false,
            showsNotificationBadge: false,
            isLoading: false,
            isAudioMuted: false,
            isPinned: false
        ),
        sourcePaneId: UUID(),
        sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
    )
    return try? JSONEncoder().encode(mirror)
}

/// NSItemProvider used by `.onDrag {}`. Registers ONLY
/// `com.splittabbar.tabtransfer` so the terminal's NSDraggingDestination
/// (which accepts `.string` / `public.utf8-plain-text`) is not hit-tested
/// for our drag. With the terminal out of the way, bonsplit's SwiftUI
/// `.onDrop(of: [.tabTransfer])` overlay can render the blue insert/split
/// zones across the entire pane (including its center).
///
/// Also mirrors the encoded blob onto NSPasteboard(name: .drag) since
/// bonsplit's external-drop decoder reads from that pasteboard directly
/// and SwiftUI's NSItemProvider bridge doesn't always surface custom
/// UTTypes there reliably.
@MainActor
func sessionDragItemProvider(for entry: SessionEntry) -> NSItemProvider {
    let dragId = SessionDragRegistry.shared.register(entry)
    let provider = NSItemProvider()

    if let data = sessionTabTransferData(for: entry, dragId: dragId) {
        provider.registerDataRepresentation(
            forTypeIdentifier: "com.splittabbar.tabtransfer",
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        let pb = NSPasteboard(name: .drag)
        let type = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
        pb.addTypes([type], owner: nil)
        pb.setData(data, forType: type)
    }

    provider.suggestedName = entry.displayTitle
    return provider
}

// MARK: - NSPopover host

/// Clears `dragCoordinator.draggedKey` after any mouseUp OR Escape keypress,
/// so a cancelled drag (user releases outside any valid drop target, or
/// presses Esc mid-drag) doesn't leave the section stuck at 0.45 opacity.
/// Successful drops clear the key themselves via
/// `SectionGapDropDelegate.performDrop` and that clear happens under
/// `DispatchQueue.main.async`, so the drop path always wins the race
/// against this fallback.
struct DragCancelMonitor: NSViewRepresentable {
    let dragCoordinator: SessionDragCoordinator

    func makeNSView(context: Context) -> NSView {
        let view = DragCancelMonitorView()
        view.dragCoordinator = dragCoordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DragCancelMonitorView)?.dragCoordinator = dragCoordinator
    }

    private final class DragCancelMonitorView: NSView {
        weak var dragCoordinator: SessionDragCoordinator?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            // Cover every way a drag can end without a drop firing:
            // mouse release (default cancellation) and Escape (AppKit
            // signals drag abort by delivering a keyDown with
            // kVK_Escape / keyCode 53). Without the Escape branch,
            // pressing Esc to cancel a section drag leaves the section
            // stuck at 0.45 opacity until the next mouseUp elsewhere.
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseUp, .otherMouseUp, .keyDown]
            ) { [weak self] event in
                guard let coordinator = self?.dragCoordinator,
                      coordinator.draggedKey != nil else { return event }
                if event.type == .keyDown, event.keyCode != 53 { // 53 = kVK_Escape
                    return event
                }
                // Defer the clear so any `performDrop` already queued on the
                // main actor wins first; this path only matters when no drop
                // fires, i.e. the drag was cancelled.
                DispatchQueue.main.async {
                    coordinator.draggedKey = nil
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
