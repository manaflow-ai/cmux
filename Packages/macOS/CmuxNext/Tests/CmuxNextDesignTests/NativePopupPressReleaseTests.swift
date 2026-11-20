import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Press-drag-release on an App-drawn popup (Lawrence via Leo, 2026-11-17: "mousedown mouseup
/// interaction not working here"). A page menu button opens its menu as a ``NativePopupHost``
/// panel on the press; the press's drags and release go to the page's window, never the panel's
/// rows. The host follows that press: the release on a row picks it, a quick release with no
/// move is a click (the popup stays), and a release dragged off every row closes it.
@MainActor @Suite(.serialized, .closesItsWindows) struct NativePopupPressReleaseTests {
    private let center = NotificationCenter()

    private struct Popup {
        let window: NSWindow
        let host: NativePopupHost
        let rows: [PopupRowView]
        func close() {
            host.closePanel()
            window.closeAfterTest()
        }

        /// The screen point at the middle of `row`.
        func point(_ row: PopupRowView) -> CGPoint {
            let mid = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            return row.window!.convertPoint(toScreen: mid)
        }
    }

    private func popup(picked: @escaping (String) -> Void) throws -> Popup {
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        let panel = NativePopupPanel(identifier: "cmux.tests.popup-press-release")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 64))
        var rows: [PopupRowView] = []
        for (index, title) in ["Copy", "Rename"].enumerated() {
            let row = PopupRowView(leading: nil, title: title)
            row.frame = NSRect(x: 0, y: 32 - CGFloat(index) * 32, width: 200, height: 32)
            row.onActivate = { picked(title) }
            content.addSubview(row)
            rows.append(row)
        }
        panel.adoptPopupStyle(card: Glass.makeOverlayPanel(content: content, cornerRadius: PopupStyle.standard.cornerRadius))
        let host = NativePopupHost(panel: panel, notificationCenter: center)
        let anchor = CGRect(x: window.frame.midX, y: window.frame.maxY - 60, width: 20, height: 20)
        try #require(host.show(size: CGSize(width: 200, height: 64), anchor: anchor, in: window) != nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        return Popup(window: window, host: host, rows: rows)
    }

    /// Fails before the fix: the release on Rename reached only the page's window; nothing ran.
    @Test func aPressDraggedOntoARowAndReleasedPicksIt() throws {
        var picked: [String] = []
        let popup = try popup { picked.append($0) }
        defer { popup.close() }
        let start = popup.host.anchor.origin
        popup.host.followHeldPress(buttons: 1, at: start, time: 10)
        let target = popup.point(popup.rows[1])
        popup.host.pressDragged(to: target)
        popup.host.pressReleased(at: target, time: 10.4)
        #expect(picked == ["Rename"])
    }

    @Test func aQuickReleaseWithNoMoveIsAClickAndLeavesThePopupOpen() throws {
        var picked: [String] = []
        let popup = try popup { picked.append($0) }
        defer { popup.close() }
        var dismissed = 0
        popup.host.onDismiss = { dismissed += 1 }
        let start = popup.host.anchor.origin
        popup.host.followHeldPress(buttons: 1, at: start, time: 10)
        popup.host.pressReleased(at: start, time: 10.05)
        #expect(picked.isEmpty)
        #expect(dismissed == 0)
        #expect(popup.host.isShown)
    }

    @Test func aPressDraggedAwayAndReleasedOffEveryRowClosesThePopup() throws {
        var picked: [String] = []
        let popup = try popup { picked.append($0) }
        defer { popup.close() }
        var dismissed = 0
        popup.host.onDismiss = { dismissed += 1 }
        let start = popup.host.anchor.origin
        popup.host.followHeldPress(buttons: 1, at: start, time: 10)
        let away = CGPoint(x: start.x - 150, y: start.y + 150)
        popup.host.pressDragged(to: away)
        popup.host.pressReleased(at: away, time: 10.5)
        #expect(picked.isEmpty)
        #expect(dismissed == 1)
    }

    @Test func aRightPressDraggedOntoARowPicksItToo() throws {
        var picked: [String] = []
        let popup = try popup { picked.append($0) }
        defer { popup.close() }
        let start = popup.host.anchor.origin
        popup.host.followHeldPress(buttons: 2, at: start, time: 10)
        let target = popup.point(popup.rows[0])
        popup.host.pressDragged(to: target)
        popup.host.pressReleased(at: target, time: 10.3)
        #expect(picked == ["Copy"])
    }

    @Test func aPopupOpenedWithNoButtonHeldFollowsNoPress() throws {
        var picked: [String] = []
        let popup = try popup { picked.append($0) }
        defer { popup.close() }
        popup.host.followHeldPress(buttons: 0, at: .zero, time: 10)
        let target = popup.point(popup.rows[1])
        popup.host.pressReleased(at: target, time: 11)
        #expect(picked.isEmpty)
    }
}
