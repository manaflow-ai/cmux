import AppKit

/// Keeps the drag panel (`HelperDragPanel`) docked to a window while a
/// grant is pending: under the System Settings window, and moving with it,
/// the way other apps' permission helpers do; when System Settings shows no
/// window, under the Computer Use sheet as its child window, so it moves with
/// the sheet. Before (user 2026-10-27) the panel sat alone at the bottom of
/// the screen, away from both windows.
///
/// Nothing polls. System Settings is another process, and following its
/// window live would need Accessibility for cmux itself, so the dock reads
/// its frame again on the events that can move it or bring it up: a mouse
/// drag or release anywhere (a global monitor of mouse events needs no
/// permission) and the pointer moving, at most once per `moveInterval`
/// (System Settings opening: the person then moves toward the panel).
@MainActor
final class HelperDragPanelDock {
    /// What the panel is docked to.
    enum Anchor: Equatable {
        /// The System Settings window at this frame.
        case systemSettings(NSRect)
        /// The Computer Use sheet (no System Settings window).
        case sheet
    }

    let panel: NSPanel
    private(set) var anchor: Anchor?
    private weak var sheet: NSWindow?
    private let locator: any SystemSettingsWindowLocating
    private let placement: HelperPanelPlacement
    private let visibleFrames: () -> [NSRect]
    private var monitor: Any?
    private var lastMoveRead: TimeInterval = -.infinity
    /// The least time between two reads on pointer moves (event timestamps, not a timer).
    static let moveInterval: TimeInterval = 1.0 / 30

    /// - Parameters:
    ///   - panel: the drag panel; the dock shows, moves and hides it.
    ///   - sheet: the Computer Use sheet, the fallback anchor.
    ///   - locator: finds the System Settings window.
    ///   - visibleFrames: the screens' visible frames (tests pass fixed ones).
    init(panel: NSPanel, sheet: NSWindow?, locator: any SystemSettingsWindowLocating = SystemSettingsWindowLocator(),
         placement: HelperPanelPlacement = HelperPanelPlacement(),
         visibleFrames: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }) {
        self.panel = panel
        self.sheet = sheet
        self.locator = locator
        self.placement = placement
        self.visibleFrames = visibleFrames
    }

    /// Docks the panel, shows it, and follows the events that can move its anchor.
    func show() {
        reposition()
        panel.orderFrontRegardless()
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { // main-proof: NSEvent.h: monitor handlers are called on the main thread
                self?.pointerEvent(event.type, timestamp: event.timestamp)
            }
        }
    }

    /// One pointer event from anywhere: a release or drag reads System
    /// Settings' frame again, a move at most once per `moveInterval`.
    func pointerEvent(_ type: NSEvent.EventType, timestamp: TimeInterval) {
        if type == .mouseMoved {
            guard timestamp - lastMoveRead >= Self.moveInterval else { return }
        }
        lastMoveRead = timestamp
        reposition()
    }

    /// Docks the panel to System Settings' window, else to the sheet.
    func reposition() {
        if let frame = locator.frame() {
            if let parent = panel.parent { parent.removeChildWindow(panel) }
            panel.level = .floating
            let visible = Self.visibleFrame(for: frame, in: visibleFrames())
            panel.setFrameOrigin(placement.origin(panel: panel.frame.size, anchor: frame, visible: visible))
            anchor = .systemSettings(frame)
            return
        }
        guard let sheet else { return }
        if panel.parent !== sheet {
            panel.parent?.removeChildWindow(panel)
            sheet.addChildWindow(panel, ordered: .above)
        }
        let visible = Self.visibleFrame(for: sheet.frame, in: visibleFrames())
        panel.setFrameOrigin(placement.origin(panel: panel.frame.size, anchor: sheet.frame, visible: visible))
        anchor = .sheet
    }

    /// Hides the panel and stops following events.
    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        anchor = nil
    }

    /// The visible frame of the screen that holds most of `rect` (the first screen when none does).
    static func visibleFrame(for rect: NSRect, in frames: [NSRect]) -> NSRect {
        let best = frames.max { lhs, rhs in
            let a = lhs.intersection(rect), b = rhs.intersection(rect)
            return a.width * a.height < b.width * b.height
        }
        guard let best, !best.intersection(rect).isEmpty else { return frames.first ?? rect }
        return best
    }
}
