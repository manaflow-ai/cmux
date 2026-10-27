import AppKit
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import Testing

/// https://github.com/manaflow-ai/cmux/issues/26076: on a scrolled Home list, rows above the
/// visible ones (the list lays out a few rows past each edge) drew, clipped and faded, under the
/// search field in the header band. The list draws nothing above its top (`listTop`).
@MainActor
struct HomeSidebarListClipTests {
    @Test(arguments: [0.5, 4.5, 10.25] as [CGFloat])
    func aScrolledListDrawsNothingUnderTheHeader(_ rowsScrolled: CGFloat) throws {
        _ = NSApplication.shared
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        defer { window.close() }
        window.contentView = home
        let now = Date()
        let entries = (0..<40).map { i in
            CmuxSidebarEntry(id: "c\(i)", title: "Chief \(i)", people: [.init(id: "p\(i)", name: "Chief \(i)", initials: "C")],
                             preview: "Finished work · 3m 49s", previewSender: nil, lastAt: now.addingTimeInterval(-Double(i) * 60),
                             unreadCount: 0, pinned: false)
        }
        home.list.show(entries, pinned: [])
        home.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()

        let controller = home.list.controller
        let clip = controller.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: rowsScrolled * SidebarMetrics.rowHeight))
        controller.scrollView.reflectScrolledClipView(clip)
        controller.tile(force: true)
        CATransaction.flush()

        let root = try #require(home.list.headerView.layer)
        let listTop = home.header.listTop
        #expect(controller.scrollView.frame.minY == listTop)
        let rows = (controller.document.layer?.sublayers ?? []).compactMap { $0 as? SidebarRowLayer }.filter { !$0.isHidden }
        #expect(!rows.isEmpty)
        if rowsScrolled >= 1 {
            // The test reaches the case: a laid-out row sits above the list's top.
            #expect(rows.contains { root.convert($0.frame, from: $0.superlayer).minY < listTop })
        }
        for row in rows {
            let shown = Self.shownRect(of: row, in: root)
            #expect(shown.isEmpty || shown.minY >= listTop - 0.5,
                    "a row draws at \(NSStringFromRect(shown)), above the list's top \(listTop)")
        }
    }

    /// Where `layer` can draw in `root`'s coordinates: its frame cut by every ancestor that clips.
    static func shownRect(of layer: CALayer, in root: CALayer) -> CGRect {
        var shown = root.convert(layer.frame, from: layer.superlayer)
        var ancestor = layer.superlayer
        while let a = ancestor, a !== root {
            if a.masksToBounds { shown = shown.intersection(root.convert(a.bounds, from: a)) }
            ancestor = a.superlayer
        }
        return shown
    }
}
