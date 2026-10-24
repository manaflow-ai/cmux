import AppKit
@testable import CmuxNextApp
@testable import CmuxNextChiefPetWiring
@testable import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextLayout
import Testing

/// The hover owners outside the design package that moved to another window under a still pointer
/// lit only on the next mouse move or key change (PointerHoverOwnerWindowMoveTests has the design
/// package's): the right sidebar's resize edge, Home's header buttons, the strip scrollbar (Move
/// Pane to New Window, a fullscreen toggle) and the Chief pet picker's cells. Each recomputes its own
/// target from `viewDidMoveToWindow` through the shared helper.
@MainActor @Suite(.serialized) struct PointerHoverOwnerWindowMoveAppTests {
    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Moves `view` (at `frame` in each window's content view) from one window into another whose
    /// pointer is at `pointer` there, and returns whether it hovers after the move. `prepare` runs
    /// once the view is in the first window.
    static func hoversAfterMove(_ view: NSView, frame: NSRect = NSRect(x: 10, y: 10, width: 24, height: 24),
                                pointer: NSPoint = NSPoint(x: 22, y: 22), prepare: () -> Void = {},
                                isHovering: () -> Bool) -> Bool {
        let from = window(), to = window()
        defer {
            PointerHover.debugPointers[ObjectIdentifier(from)] = nil
            PointerHover.debugPointers[ObjectIdentifier(to)] = nil
            from.close()
            to.close()
        }
        view.frame = frame
        from.contentView?.addSubview(view)
        prepare()
        PointerHover.setDebugPointer(nil, in: from)
        #expect(!isHovering())
        PointerHover.setDebugPointer(pointer, in: to)
        to.contentView?.addSubview(view)
        return isHovering()
    }

    @Test func theRightSidebarResizeEdgeMovedUnderAStillPointerHoversAtOnce() {
        let handle = RightSidebarResizeHandle(frame: .zero)
        #expect(Self.hoversAfterMove(handle) { handle.isHovered })
    }

    @Test func aHomeHeaderButtonMovedUnderAStillPointerHoversAtOnce() {
        let button = HomeHeaderButton(symbol: "sidebar.left", label: "Sidebar", identifier: "cmux.test.homeHeader")
        #expect(Self.hoversAfterMove(button) { button.hover.state.hovering })
    }

    @Test func theStripScrollbarMovedUnderAStillPointerHoversAtOnce() {
        let bar = StripScrollbarView(hideClock: ManualClock())
        let band = NSRect(x: 10, y: 10, width: 200, height: StripScrollbarView.bandHeight)
        let shown = Self.hoversAfterMove(bar, frame: band, pointer: NSPoint(x: 40, y: band.midY), prepare: {
            bar.update(StripScrollbarView.Input(mode: .always, band: band, offset: 0, contentWidth: 1600,
                                                viewportWidth: 400, snaps: []), scrolled: false)
        }) { bar.isHovered }
        #expect(shown)
    }

    @Test func aChiefPetCellMovedUnderAStillPointerHoversAtOnce() {
        let cell = ChiefPetMascotCell(id: "cat", title: "Cat")
        #expect(Self.hoversAfterMove(cell) { cell.hover.state.hovering })
    }
}
