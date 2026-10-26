import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Testing

/// The p06-scheduler-328 sweep of CmuxNextSidebar/Views (second half): the notice card reads its own
/// visibility node instead of walking its ancestors, and the sidebar list follows the scroll-bar setting
/// through the app's one observer (plans/cmux-next/chrome-parity/p06-scheduler.md, recipes R-vis, R-hide,
/// R-appear and R-notif).
@MainActor @Suite(.serialized) struct SidebarViewsSchedulerSweepTests {
    static let tip = SidebarNoticeCard(id: "tip", title: "Command Palette", dismissLabel: "Close", shownAction: "tip.shown")

    /// A window whose node reads visible (it is never ordered in), holding `host`.
    private static func window(holding host: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.isReleasedWhenClosed = false
        _ = WindowVisibilitySource.of(window, read: { _ in .visible })
        window.contentView = host
        return window
    }

    /// A notice under a collapsed sidebar is not reported shown; the sidebar opening reports it once,
    /// through the card's node (no unhide override does it any more).
    @Test func aNoticeIsReportedShownWhenItsNodeShows() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let window = Self.window(holding: host)
        defer { window.close() }
        host.isHidden = true
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 240, height: SidebarNoticeCardView.height(for: Self.tip)))
        host.addSubview(card)
        var sent: [String] = []
        card.onAction = { _, action in sent.append(action) }
        card.configure(Self.tip)
        #expect(!card.loopNode.isVisible, "the card's node is visible under a hidden sidebar")
        #expect(sent.isEmpty, "a notice under a hidden sidebar was reported shown: \(sent)")
        host.isHidden = false
        #expect(card.loopNode.isVisible, "the card's node did not show with the sidebar")
        #expect(sent == ["tip.shown"], "showing the sidebar did not report the notice once: \(sent)")
        host.isHidden = true
        host.isHidden = false
        #expect(sent == ["tip.shown"], "a second show reported the same notice again: \(sent)")
    }

    /// An appearance change while the card is hidden repaints nothing then and once when it shows.
    @Test func aHiddenCardRepaintsItsAppearanceOnceOnShow() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let window = Self.window(holding: host)
        defer { window.close() }
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 240, height: SidebarNoticeCardView.height(for: Self.tip)))
        host.addSubview(card)
        card.configure(Self.tip)
        #expect(card.loopNode.isVisible, "a shown card's node is not visible")
        host.isHidden = true
        card.appearance = NSAppearance(named: .darkAqua)
        card.appearance = NSAppearance(named: .aqua)
        #expect(card.loopNode.deferredCount == 1, "two hidden appearance changes left \(card.loopNode.deferredCount) repaints, not one")
        host.isHidden = false
        #expect(card.loopNode.deferredCount == 0, "the deferred repaint did not run on show")
        card.appearance = NSAppearance(named: .darkAqua)
        #expect(card.loopNode.deferredCount == 0, "a shown card deferred its repaint")
    }

    /// A change of the "Show scroll bars" setting reaches the sidebar through SystemScrollers: the scroller
    /// stays the overlay one and the list fits the clip again.
    @Test func theListFitsTheClipAfterAScrollBarSettingChange() {
        let sidebar = SidebarView(model: SidebarModel(), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        let clipWidth = sidebar.scrollView.contentView.bounds.width
        #expect(clipWidth > 0, "the sidebar's clip has no width")
        sidebar.scrollView.scrollerStyle = .legacy
        sidebar.list.setFrameSize(NSSize(width: 10, height: sidebar.list.frame.height))
        SystemScrollers.systemStyleDidChange()
        #expect(sidebar.scrollView.scrollerStyle == SystemScrollers.nativeStyle, "the sidebar's scroller left the overlay style")
        #expect(sidebar.list.frame.width == sidebar.scrollView.contentView.bounds.width,
                "the list is \(sidebar.list.frame.width) wide, the clip \(sidebar.scrollView.contentView.bounds.width)")
    }
}
