import AppKit
@testable import CmuxNextPalette
import Testing

/// The palette's results keep AppKit's responsive scrolling: the list opts in, neither
/// it nor its table takes wheel events, and the table draws nothing of its own, so AppKit scrolls it off the
/// main thread and a main-thread stall does not stop the scroll.
@MainActor
struct PaletteListResponsiveScrollingTests {
    @Test func theResultsScrollResponsively() throws {
        let list = PaletteListView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))
        #expect(PaletteListView.isCompatibleWithResponsiveScrolling)
        let wheel = #selector(NSResponder.scrollWheel(with:))
        let draw = #selector(NSView.draw(_:))
        #expect(PaletteListView.instanceMethod(for: wheel) == NSScrollView.instanceMethod(for: wheel))
        let document = try #require(list.documentView)
        #expect(document is PaletteTableView)
        #expect(type(of: document).instanceMethod(for: wheel) == NSTableView.instanceMethod(for: wheel))
        #expect(type(of: document).isCompatibleWithResponsiveScrolling
            || type(of: document).instanceMethod(for: draw) == NSTableView.instanceMethod(for: draw))
    }
}
