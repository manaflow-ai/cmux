#if os(iOS)
import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// Leo's iPhone (2026-11-15): a Claude Code tab whose shared grid is 36 columns (the Mac's
/// "smallest" policy) showed an empty band and no reason for it: the "36×26" corner chip was
/// drawn under the floating Chat | Terminal control. With that control over the page the chip
/// goes below it.
@MainActor @Suite struct HostGridNoteCornerTests {
    /// An iPhone 17 Pro page: 402 pt wide, the status bar 62 pt tall, a "36×26" chip.
    let width: CGFloat = 402
    let areaTop: CGFloat = 62
    let chip = CGSize(width: 44, height: 20)

    /// `TerminalChatToggleControl` in CmuxMobileWorkspaces: 8 pt below the top inset, 12 pt in
    /// from the trailing edge, two 40 pt segments 2 pt apart on 3 pt of glass (88 × 38), and
    /// its page reserve (`pageReserve`): 8 + 38 + 6.
    var toggle: CGRect { CGRect(x: width - 12 - 88, y: areaTop + 8, width: 88, height: 38) }
    let pageReserve: CGFloat = 8 + 38 + 6

    private func corner(reserve: CGFloat) -> CGRect {
        HostGridNoteSpot.cornerFrame(size: chip, viewWidth: width, sidePadding: TerminalViewController.sidePadding,
                                     areaTop: areaTop, topTrailingReserve: reserve)
    }

    @Test func withoutAControlTheChipStaysInTheCorner() {
        #expect(corner(reserve: 0) == CGRect(x: width - TerminalViewController.sidePadding - chip.width, y: areaTop + 4,
                                             width: chip.width, height: chip.height))
        // The bug: the chip was under the control.
        #expect(corner(reserve: 0).intersects(toggle))
    }

    @Test func underTheChatTerminalControlTheChipGoesBelowIt() {
        let frame = corner(reserve: pageReserve)
        #expect(!frame.intersects(toggle))
        #expect(frame.minY == toggle.maxY + 6)
        #expect(frame.maxX == width - TerminalViewController.sidePadding)
    }
}
#endif
