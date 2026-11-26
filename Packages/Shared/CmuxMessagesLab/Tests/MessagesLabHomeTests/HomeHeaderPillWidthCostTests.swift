import AppKit
import Testing
@testable import MessagesLabHome

/// Every layout of Home's header measured the name pill again: its title in the bold font (`HeaderBar.pillWidth`) and
/// the button's own size (`intrinsicContentSize`), and a divider drag lays the header out at every width (about 24
/// samples of the header's layout in the sampled drags, release-resize bp-on-2, 2026-11-26). The pill's width depends
/// on its title and its look, not on the header's width: it is measured when those change, and a width change measures
/// nothing.
@MainActor @Suite(.serialized) struct HomeHeaderPillWidthCostTests {
    /// A header in an offscreen window, as in a pane.
    private func header(_ title: String, width: CGFloat = 700) -> (NSWindow, PaneHeaderView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: width, height: 80))
        window.contentView?.addSubview(header)
        header.title = title
        header.layoutSubtreeIfNeeded()
        return (window, header)
    }

    private func resize(_ header: PaneHeaderView, to width: CGFloat) {
        header.setFrameSize(NSSize(width: width, height: 80))
        header.layoutSubtreeIfNeeded()
    }

    @Test func aWidthChangeMeasuresNoPill() {
        let (window, header) = header("Chief")
        defer { window.close() }
        let before = PaneHeaderView.pillMeasurements
        for width in [680.0, 650, 620, 590, 560, 530, 500, 470] { resize(header, to: width) }
        let measured = PaneHeaderView.pillMeasurements - before
        #expect(measured == 0, "\(measured) pill measurements across 8 width changes; a width change measures nothing")
    }

    /// A new title is measured, and the pill takes its width at once (centered, as before).
    @Test func aNewTitleTakesItsWidth() {
        let (window, header) = header("Chief")
        defer { window.close() }
        let short = header.pill.frame.width
        header.title = "workspace-1005"
        header.layoutSubtreeIfNeeded()
        let long = header.pill.frame.width
        #expect(long > short, "the pill kept \"Chief\"'s width (\(short) pt) for a longer title (\(long) pt)")
        #expect(long >= header.pill.intrinsicContentSize.width - 0.5, "the pill is narrower than its button needs")
        resize(header, to: 600)
        #expect(header.pill.frame.width == long, "a width change gave the pill another width")
        #expect(abs(header.pill.frame.midX - 300) <= 0.5, "the pill is not centered at 600 pt: \(header.pill.frame)")
    }
}
