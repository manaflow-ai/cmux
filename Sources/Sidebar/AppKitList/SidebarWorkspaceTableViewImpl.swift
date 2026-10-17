import AppKit

/// Decides whether a row double-click is a deliberate rename gesture.
///
/// The window server counts the click that activates cmux as the first click
/// of a double-click, so the next press on the same row arrives with
/// `clickCount == 2` and would start an inline rename although the user only
/// meant to focus the workspace (issue #21227). A double-click renames only
/// when its first press reached this row while the window was already key.
struct SidebarRowRenameClickGate {
    /// Seconds after an activation during which a press counts as the
    /// activating click.
    static let activationGrace: TimeInterval = 0.3

    private var lastActivationTimestamp: TimeInterval?
    private var renameEligibleRow: Int?

    /// Records the window or app becoming active, in `NSEvent.timestamp` time.
    mutating func noteActivation(at timestamp: TimeInterval) {
        lastActivationTimestamp = timestamp
        renameEligibleRow = nil
    }

    /// Records a row press. Returns whether a `clickCount == 2` press may
    /// begin an inline rename.
    @discardableResult
    mutating func notePress(
        row: Int,
        clickCount: Int,
        timestamp: TimeInterval,
        windowIsKey: Bool
    ) -> Bool {
        if clickCount <= 1 {
            renameEligibleRow = Self.isDeliberatePress(
                timestamp: timestamp,
                windowIsKey: windowIsKey,
                lastActivationTimestamp: lastActivationTimestamp
            ) && row >= 0 ? row : nil
            return false
        }
        let eligible = clickCount == 2 && row >= 0 && renameEligibleRow == row
        renameEligibleRow = nil
        return eligible
    }

    private static func isDeliberatePress(
        timestamp: TimeInterval,
        windowIsKey: Bool,
        lastActivationTimestamp: TimeInterval?
    ) -> Bool {
        guard windowIsKey else { return false }
        guard let lastActivationTimestamp else { return true }
        return timestamp - lastActivationTimestamp > activationGrace
    }
}

/// Event-owning NSTableView for the default workspace sidebar.
@MainActor
final class SidebarWorkspaceTableViewImpl: NSTableView {
    weak var workspaceController: SidebarWorkspaceTableController?
    /// AppKit can retain this table as a native drag source after SwiftUI
    /// dismantles its representable. Keep the controller alive until the
    /// terminal source callback arrives.
    var activeWorkspaceDragController: SidebarWorkspaceTableController?
    private let emptyAreaWindowDragController = SidebarEmptyAreaWindowDragController()
    private var pointerTrackingArea: NSTrackingArea?
    private(set) var lastPointerWindowLocation: NSPoint?
    private var renameClickGate = SidebarRowRenameClickGate()
    /// Whether the press that triggered the current `doubleAction` may begin
    /// an inline rename; see ``SidebarRowRenameClickGate``.
    private(set) var currentDoubleClickMayRename = false
    private var activationObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activationObservers = []
        renameClickGate = SidebarRowRenameClickGate()
        guard let window else { return }
        let noteActivation: @Sendable (Notification) -> Void = { [weak self] _ in
            let now = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated {
                self?.renameClickGate.noteActivation(at: now)
            }
        }
        activationObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main,
                using: noteActivation
            ),
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main,
                using: noteActivation
            ),
        ]
    }

    /// Pointer location for hover recomputes that no event drove (content
    /// applies, menu close, viewport changes). Tracking events stop while a
    /// context menu or drag session runs, so the cached point can be where
    /// the pointer was when the menu opened. "Close Workspace" from a row
    /// menu then revealed the X on whichever row slid into that old spot.
    /// Read the live pointer instead, and only while the tracking area
    /// still has the pointer inside the table.
    var livePointerWindowLocation: NSPoint? {
        guard lastPointerWindowLocation != nil, let window else { return nil }
        return window.mouseLocationOutsideOfEventStream
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        pointerTrackingArea = next
        SidebarReorderInteractionState.shared.register(table: self)
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointer(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setPointerWindowLocation(nil)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else {
            super.otherMouseDown(with: event)
            return
        }
        workspaceController?.middleClick(row: row)
    }

    /// Preserves row clicks while promoting threshold-crossing empty-area presses to window drags.
    override func mouseDown(with event: NSEvent) {
        workspaceController?.prepareForMouseDown()
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        currentDoubleClickMayRename = renameClickGate.notePress(
            row: clickedRow,
            clickCount: event.clickCount,
            timestamp: event.timestamp,
            windowIsKey: window?.isKeyWindow == true && NSApp.isActive
        )
        // Below the last row the press is window-drag territory. Single clicks
        // only: a double-click still belongs to doubleClickEmptyArea().
        if clickedRow < 0, event.clickCount == 1,
           emptyAreaWindowDragController.perform(with: event, in: self) != .passThrough {
            return
        }
        // No selection paint on press: the highlight applies on down-then-up
        // (owner ruling). The action fires on mouse-up and paints the
        // optimistic treatment there, so a press that becomes a drag or a
        // cancelled click never shows a speculative highlight at all.
        super.mouseDown(with: event)
        if event.clickCount == 2, clickedRow < 0 {
            workspaceController?.doubleClickEmptyArea()
        }
    }

    /// Focus Sidebar hands this list the keyboard: arrows step workspaces,
    /// Return and Escape go back to the selected workspace.
    override func keyDown(with event: NSEvent) {
        if AppDelegate.shared?.handleSidebarKeyboardKey(event, in: self) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row < 0 else { return super.menu(for: event) }
        return workspaceController?.emptyAreaMenu()
    }

    private func updatePointer(with event: NSEvent) {
        setPointerWindowLocation(event.locationInWindow)
    }

    func setPointerWindowLocation(_ point: NSPoint?) {
        lastPointerWindowLocation = point
        if point == nil {
            workspaceController?.pointerDidLeaveTable()
        } else {
            workspaceController?.recomputeHoveredRow(windowPoint: point)
        }
    }
}
