import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
import Testing

/// https://github.com/manaflow-ai/cmux/issues/46908 (review of https://github.com/manaflow-ai/cmux/pull/48537): going
/// into a pane takes its ring only when it clears every reason the ring draws for. A tab marked unread by hand that also
/// holds an unread notification the policy keeps (`never`) still rings after a click: the click reads the mark, not the
/// notification, so the ring must stay, not blink out and stay hidden while the notification is unread.
extension FocusUnreadPaneFlashTests {
    @Test func aClickThatReadsOnlyTheMarkKeepsTheNotificationsRing() async throws {
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let notifications = fixture.services.notifications
        notifications.preferences.dismissal = .never
        let tab = try #require(fixture.unread.tabs.first)
        tab.applyState(SessionStateMirror.TabRecord(markedUnread: true), progress: nil)
        #expect(tab.hasUnread && tab.markedUnread, "the tab is not both notified and marked")
        let pane = LayoutPaneID(fixture.unread.id)
        let model = fixture.content.layoutModel
        try await PinnedPageTests.until({ model.attention[pane] != nil }, report: { "the pane does not ring" })
        let host = try #require(Self.partialReadHost(of: pane, in: fixture.content.layoutView), "the pane has no host view")
        fixture.content.contentView.layoutSubtreeIfNeeded()
        let point = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)

        notifications.noteMouseDown(in: fixture.window, at: point, synthetic: true)
        #expect(model.attention[pane] != nil, "a click that reads only the mark took the ring of a notification the policy keeps")
        #expect(!model.attentionReadByEntry.contains(pane), "the ring blinked out though the notification stays unread")
        #expect(tab.hasUnread, "the click read a notification the policy keeps")
    }

    private static func partialReadHost(of pane: LayoutPaneID, in view: NSView) -> PaneHostView? {
        if let host = view as? PaneHostView, host.pane == pane { return host }
        for child in view.subviews { if let found = partialReadHost(of: pane, in: child) { return found } }
        return nil
    }
}
