import AppKit
import Testing
@testable import MessagesLabSidebar

/// PINNED GRID CENTRE (the user, 2026-11-25, a Chief sidebar shot: one pinned Chief sat in the left
/// column of a wide list). As in Messages, a last pinned row with fewer tiles than columns is centred in
/// the list at every width; full rows keep the grid. A drag's slot under the pointer follows the same layout.
@MainActor
@Suite(.serialized)
struct PinnedGridCentreTests {
    private static let widths: [CGFloat] = [SidebarMetrics.compactBelow, 220, 260, SidebarMetrics.preferredWidth, 480, 628]

    @Test func lastRowIsCentredAndFullRowsKeepTheGrid() {
        for width in Self.widths {
            let m = SidebarMetrics(width: width)
            let cols = m.columns
            for count in 1...(2 * cols + 1) {
                let rows = (count + cols - 1) / cols
                for r in 0..<rows {
                    let first = r * cols, last = min(count, first + cols) - 1
                    let left = m.tileRect(first, count: count).minX, right = m.tileRect(last, count: count).maxX
                    #expect(abs((left + right) / 2 - width / 2) <= 0.5,
                            "width \(width), \(count) pinned, row \(r): tiles \(left)...\(right) centred on \(width / 2)")
                    if last - first + 1 == cols {
                        #expect(left == ((width - m.tileWidth * CGFloat(cols)) / 2).rounded(), "width \(width), \(count) pinned: a full row keeps the grid")
                    }
                    for t in first...last {
                        let rect = m.tileRect(t, count: count)
                        #expect(rect.minX == rect.minX.rounded(), "width \(width), \(count) pinned, tile \(t): on whole points")
                        #expect(m.tileSlot(at: CGPoint(x: rect.midX, y: rect.midY), count: count) == t,
                                "width \(width), \(count) pinned: the slot under tile \(t)'s centre")
                    }
                }
            }
        }
    }

    @Test func slotBesideAShortRowClampsToItsEnds() {
        let m = SidebarMetrics(width: SidebarMetrics.preferredWidth)
        let y = m.tileHeight / 2
        #expect(m.tileSlot(at: CGPoint(x: 1, y: y), count: 1) == 0)
        #expect(m.tileSlot(at: CGPoint(x: m.width - 1, y: y), count: 1) == 0)
        #expect(m.tileSlot(at: CGPoint(x: 1, y: m.tileHeight + y), count: 5) == 3)
        #expect(m.tileSlot(at: CGPoint(x: m.width - 1, y: m.tileHeight + y), count: 5) == 4)
    }

    @Test func oneDrawnPinStaysCentredAcrossAResize() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = (0..<3).map { i in
            CmuxSidebarEntry(id: "c\(i)", title: "Chat \(i)", people: [.init(id: "p\(i)", name: "Chat \(i)", initials: "C\(i)")],
                             preview: "hello", previewSender: nil, lastAt: now.addingTimeInterval(-Double(i) * 60),
                             unreadCount: 0, pinned: i == 0)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let view = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 800))
        window.contentView = view
        view.show(entries, pinned: ["c0"])
        for width: CGFloat in [320, 628, 260] {
            view.setFrameSize(NSSize(width: width, height: 800))
            view.layoutSubtreeIfNeeded()
            view.controller.view.layoutSubtreeIfNeeded()
            view.controller.document.layoutSubtreeIfNeeded()
            view.controller.tile(force: true)
            let tile = try #require(view.controller.tileLayers.first)
            let listWidth = view.controller.metrics.width
            #expect(abs(tile.frame.midX - listWidth / 2) <= 0.5, "width \(width): the one pin at \(tile.frame) centred on \(listWidth / 2)")
        }
    }
}
