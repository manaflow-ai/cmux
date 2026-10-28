import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import Testing

/// A scroll under a still pointer moves hover to the row now under it, pushed from the list's clip
/// (before, from a NotificationCenter observer of the clip). The palette's edge fade
/// and scroll fit share that clip, so the list's push must survive them attaching.
@MainActor
struct PaletteListScrollHoverTests {
    private static func item(_ index: Int) -> PaletteRow {
        let item = PaletteItem(id: "r\(index)", title: "Row \(index)",
                               primary: PaletteCommand(id: "open", title: "Open", symbol: "return", effect: .perform {}))
        return PaletteRow(item: item, highlights: [], score: 0)
    }

    /// The list as `PaletteContentView` hosts it: inside its edge fade, in a window.
    private static func hostedList() -> (PaletteListView, ScrollEdgeFadeView, NSWindow) {
        _ = NSApplication.shared
        let list = PaletteListView()
        let host = ScrollEdgeFadeView(scrollView: list)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 10 * PaletteLayout.rowHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        let section = PaletteSection(id: "rows", title: "", order: 0)
        list.setSections([PaletteResultSection(section: section, rows: (0..<60).map(item))])
        host.layoutSubtreeIfNeeded()
        list.tile()
        return (list, host, window)
    }

    @Test func theClipIsTheSharedGeometryClip() {
        let (list, _, window) = Self.hostedList()
        defer { window.close() }
        #expect(list.contentView is ScrollGeometryClipView)
    }

    @Test func aScrollUnderAStillPointerHoversTheRowNowUnderIt() throws {
        let (list, _, window) = Self.hostedList()
        defer { window.close() }
        let rowHeight = PaletteLayout.rowHeight
        let clip = list.contentView
        try #require(list.documentView.map { $0.frame.width > 0 && $0.frame.height > 20 * rowHeight } == true)
        // The pointer rests over row 2 and never moves.
        let pointer = clip.convert(NSPoint(x: 4, y: clip.bounds.minY + 2.5 * rowHeight), to: nil)
        list.pointerLocation = { _ in pointer }
        var hovered: [String?] = []
        list.onHover = { hovered.append($0) }
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 10 * rowHeight))
        #expect(hovered.last == "r12")
    }
}
