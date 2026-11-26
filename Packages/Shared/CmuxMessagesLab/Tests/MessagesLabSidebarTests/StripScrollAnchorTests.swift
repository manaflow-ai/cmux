import AppKit
import Testing
@testable import MessagesLabSidebar

/// cmux: the avatar strip's rows grow with its width (the user, 2026-11-24: "make them bigger here"), so a width change
/// keeps the row at the list's top where it was, and the line under the pinned avatars stays on whole points.
@MainActor
@Suite(.serialized)
struct StripScrollAnchorTests {
    private func strip(width: CGFloat) -> (NSWindow, CmuxSidebarView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let list = (0..<40).map { i in
            CmuxSidebarEntry(id: "c\(i)", title: "Person \(i)", people: [.init(id: "p\(i)", name: "Person \(i)", initials: "P\(i % 10)")],
                             preview: "hello", previewSender: nil, lastAt: now.addingTimeInterval(-Double(i) * 60), unreadCount: 0, pinned: i < 2)
        }
        window.contentView = view
        view.show(list, pinned: ["c0", "c1"])
        settle(view)
        return (window, view)
    }

    private func settle(_ view: CmuxSidebarView) {
        view.layoutSubtreeIfNeeded()
        view.controller.view.layoutSubtreeIfNeeded()
        view.controller.document.layoutSubtreeIfNeeded()
    }

    @Test(arguments: [(SidebarMetrics.minimumWidth, 150), (150, 110), (170, SidebarMetrics.minimumWidth)] as [(CGFloat, CGFloat)])
    func aWidthChangeKeepsTheTopRow(from: CGFloat, to: CGFloat) {
        let (window, view) = strip(width: from)
        defer { window.close() }
        let c = view.controller
        #expect(c.metrics.compact)
        let clip = c.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: c.rowRect(20).minY))
        c.scrollView.reflectScrolledClipView(clip)
        view.frame.size.width = to
        window.setContentSize(NSSize(width: to, height: 600))
        settle(view)
        #expect(c.metrics.width != from, "the width did not change")
        #expect(abs(clip.bounds.minY - c.rowRect(20).minY) <= 1, "row 20 at \(c.rowRect(20).minY), the top at \(clip.bounds.minY)")
    }

    @Test func theLineUnderThePinnedAvatarsIsOnWholePoints() {
        for w in stride(from: SidebarMetrics.minimumWidth, to: SidebarMetrics.compactBelow, by: 1) {
            let m = SidebarMetrics(width: w)
            #expect(m.compactDividerGapScaled.truncatingRemainder(dividingBy: 2) == 0, "a \(m.compactDividerGapScaled) pt gap at \(w) pt")
        }
    }
}
