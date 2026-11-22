import AppKit

/// Press-drag-release, the macOS menu gesture, for a popup that opened during a held press
/// outside it (Lawrence via Leo, 2026-11-17: "so he click and hold on the context menu start and
/// then it goes over and then release should go"). A page menu button or a right-click opens its
/// popup on the press; AppKit keeps sending that press's drags and its release to the window
/// where it began (the page's web view), so the popup's rows never see them. This follows the
/// press for the popup: a drag over a row highlights it, and the release on a row activates it.
/// A release soon after the press without moving is a click and leaves the popup open; a release
/// after dragging away, not on a row, closes it. The same rules as the page's `pressRelease.ts`.
@MainActor
final class PopupPressRelease {
    /// A release this soon after the press is a click, never a pick or a close (`PRESS_CLICK_MS`).
    static let clickTime: TimeInterval = 0.15
    /// How far the pointer moves (points) before the press counts as a drag.
    static let slop: CGFloat = 4

    private weak var panel: NSWindow?
    private let start: CGPoint
    private let startedAt: TimeInterval
    private var moved = false
    private weak var over: PopupRowView?

    /// `start` is the pointer (screen) and `startedAt` the time (`systemUptime`, as `NSEvent.timestamp`)
    /// when the popup opened under the held press.
    init(panel: NSWindow, start: CGPoint, startedAt: TimeInterval) {
        self.panel = panel
        self.start = start
        self.startedAt = startedAt
    }

    /// The held press is at `point` (screen).
    func dragged(to point: CGPoint) {
        if !moved { moved = hypot(point.x - start.x, point.y - start.y) >= Self.slop }
        guard moved else { return }
        let row = row(at: point)
        if row !== over {
            over?.pressLeft()
            over = row
            row?.pressEntered()
        }
    }

    /// What the release did.
    enum Outcome: Equatable { case picked, closes, none }

    /// The press is released at `point` (screen) at `time`: a row there activates, or the popup
    /// closes (``Outcome/closes``, the host dismisses it).
    func released(at point: CGPoint, time: TimeInterval) -> Outcome {
        if !moved { moved = hypot(point.x - start.x, point.y - start.y) >= Self.slop }
        let held = time - startedAt >= Self.clickTime
        over?.pressLeft()
        over = nil
        if moved || held, let row = row(at: point), row.pressReleased() { return .picked }
        return moved && held ? .closes : .none
    }

    /// The enabled row of the popup under `point` (screen), if any.
    func row(at point: CGPoint) -> PopupRowView? {
        guard let panel, panel.isVisible, let content = panel.contentView, panel.frame.contains(point) else { return nil }
        let inWindow = panel.convertPoint(fromScreen: point)
        let local = content.superview?.convert(inWindow, from: nil) ?? inWindow
        var view = content.hitTest(local)
        while let current = view {
            if let row = current as? PopupRowView { return row.isEnabled && row.isInteractive ? row : nil }
            view = current.superview
        }
        return nil
    }
}
