import CmuxNextLayout
import CoreGraphics
import Testing

/// A tab an agent or the chat header opens beside a chat docked left (cx-27j7): its new column scrolls
/// into view while keyboard focus stays in the chat. The strip only follows focus, and the chat's dock
/// is no strip column, so without this the column could land past the viewport.
@MainActor
struct BesideColumnRevealTests {
    /// A strip behind a 400 pt chat dock on a 1000 pt window: two 600 pt terminals, and a 600 pt diff
    /// column added past them (the daemon stores the dock last, so a new column goes after the strip).
    private static func strip(columns: Int) -> ColumnStrip {
        let all = (0..<columns).map { index in
            ColumnStrip.Column(id: ColumnID("c\(index)"), frame: CGRect(x: CGFloat(index) * 616, y: 0, width: 600, height: 800),
                               panes: [PaneID("p\(index)")])
        }
        var strip = ColumnStrip(columns: all, viewportWidth: 1000, contentWidth: CGFloat(columns) * 616 - 16, gap: 16)
        strip.leadingCover = 400
        return strip
    }

    @Test func theNewColumnScrollsIntoViewAndFocusStaysInTheChat() {
        var state = ColumnScrollState()
        let chat = PaneID("chat")
        state.reduce(.sync(Self.strip(columns: 2), focused: chat, source: .programmatic, animated: false))
        state.reduce(.sync(Self.strip(columns: 3), focused: chat, source: .programmatic, animated: false))
        let diff = Self.strip(columns: 3).columns[2].frame
        // Before: the diff's column starts past the window's right edge.
        #expect(state.spring.target + 1000 <= diff.minX)

        state.reduce(.reveal(PaneID("p2"), animated: false))
        let start = state.spring.target + 400, end = state.spring.target + 1000
        #expect(start <= diff.minX + 0.5 && diff.maxX <= end + 0.5)
        #expect(state.focusedPane == chat)
        // The next snapshot, focus still in the chat, keeps it there.
        state.reduce(.sync(Self.strip(columns: 3), focused: chat, source: .programmatic, animated: false))
        #expect(state.spring.target + 400 <= diff.minX + 0.5)
    }

    /// The layout asks for the reveal without moving focus, so the window's views can apply it once
    /// the new column is in the strip.
    @Test func revealingAColumnLeavesFocusWhereItWas() {
        let columns: [LayoutColumn] = [LayoutColumn(id: "c0", root: .leaf("chat")), LayoutColumn(id: "c1", root: .leaf("p1"))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s",
                                focusedPane: "chat")
        model.revealColumn(containing: "p1")
        #expect(model.focusedPane == "chat")
        #expect(model.revealRequest?.pane == "p1")
        let first = model.revealRequest
        model.revealColumn(containing: "p1")
        #expect(model.revealRequest != first)
    }
}
