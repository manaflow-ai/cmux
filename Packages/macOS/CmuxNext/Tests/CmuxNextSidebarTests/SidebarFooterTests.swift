import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// SIDEBAR-FOOTER-MINIMAL (Lawrence 2026-10-06, "this is jank"): the footer
/// is one line with no separator over it: the avatar, then the gear. A
/// staged update is the card above it (UPDATE-CARD, SidebarUpdateCardTests).
/// Before, a hairline sat over a floating "?" button and a "Settings" text
/// row with an accent arrow.
@MainActor @Suite(.serialized) struct SidebarFooterTests {
    private func sidebar(width: CGFloat = 260, intents: ((SidebarIntent) -> Void)? = nil) -> SidebarView {
        let model = SidebarModel()
        model.onIntent = intents
        let view = SidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// No help button and no hairline over the footer: the only band line is
    /// the one under the top band.
    @Test func theFooterHasNoHelpButtonAndNoLine() {
        let view = sidebar()
        #expect(view.footer.subviews.allSatisfy { $0 === view.profileBar }, "only the spaces dots remain in the footer row")
        let lines = (view.layer?.sublayers ?? []).filter { $0.frame.height == Metrics.dividerThickness && !$0.isHidden }
        #expect(lines.allSatisfy { $0 === view.aboveLine })
        #expect(lines.allSatisfy { $0.frame.maxY <= view.belowFade.frame.minY - SidebarStyle.footerHeight })
    }
}
