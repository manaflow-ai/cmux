import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// SIDEBAR-FOOTER-MINIMAL (Lawrence 2026-10-06, "this is jank"): the footer
/// is one line with no separator over it: the avatar, then the gear, and
/// only while an update is staged an "Update Ready" pill at its trailing
/// end. Before, a hairline sat over a floating "?" button and a "Settings"
/// text row with an accent arrow.
@MainActor @Suite(.serialized) struct SidebarFooterTests {
    static let pill = SidebarUpdatePill(title: "Update Ready", help: "Restart to update. Your terminals and agents keep running.")

    private func sidebar(width: CGFloat = 260, intents: ((SidebarIntent) -> Void)? = nil) -> SidebarView {
        let model = SidebarModel()
        model.onIntent = intents
        let view = SidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func show(_ pill: SidebarUpdatePill?, in view: SidebarView) async {
        view.model.updatePill = pill
        for _ in 0..<200 where view.updatePillView.pill != pill { await Task.yield() }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    @Test func noUpdateShowsNoPill() {
        let view = sidebar()
        #expect(view.updatePillView.isHidden)
        #expect(view.updatePillView.frame == .zero)
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

    /// A staged update: the pill trails the avatar and gear's line, centered
    /// on it, clear of the gear, labelled and described for VoiceOver.
    @Test func aStagedUpdateShowsThePillTrailingTheFooterLine() async throws {
        let view = sidebar()
        await show(Self.pill, in: view)
        let pill = view.updatePillView
        #expect(!pill.isHidden)
        #expect(pill.shownTitle == "Update Ready")
        #expect(pill.toolTip == Self.pill.help)
        #expect(pill.accessibilityLabel() == Self.pill.help)
        #expect(pill.accessibilityRole() == .button)
        let gear = try #require(view.belowRegion.itemView(LayoutItemID("itm_settings")))
        let gearFrame = view.convert(gear.frame, from: view.belowRegion)
        #expect(abs(pill.frame.midY - gearFrame.midY) <= 1, "centered on the footer line: \(pill.frame) \(gearFrame)")
        #expect(pill.frame.minX > gearFrame.maxX, "after the gear")
        #expect(abs(pill.frame.maxX - (view.bounds.width - SidebarStyle.horizontalInset)) <= 1, "at the trailing inset")
        await show(nil, in: view)
        #expect(pill.isHidden)
    }

    /// One click installs: the pill sends `installUpdate` once; a disabled
    /// pill (installing) sends nothing.
    @Test func aClickSendsInstallUpdate() async {
        var intents: [SidebarIntent] = []
        let view = sidebar { intents.append($0) }
        await show(Self.pill, in: view)
        view.updatePillView.press()
        #expect(intents == [.installUpdate])
        #expect(view.updatePillView.accessibilityPerformPress())
        #expect(intents == [.installUpdate, .installUpdate])
        var installing = Self.pill
        installing.isEnabled = false
        await show(installing, in: view)
        view.updatePillView.press()
        #expect(!view.updatePillView.accessibilityPerformPress())
        #expect(intents.count == 2)
    }

    /// A neutral fill and the primary text color: never the accent.
    @Test func thePillIsNeutral() async {
        let view = sidebar()
        await show(Self.pill, in: view)
        let pill = view.updatePillView
        pill.updateLayer()
        #expect(pill.fill == pill.performWithTheme { Palette.hoverFill })
        #expect(pill.fill != pill.performWithTheme { Palette.highlight })
    }

    /// A narrow sidebar keeps the pill on the line as a glyph-only circle.
    @Test func aNarrowFooterShowsTheGlyphOnly() async {
        let view = sidebar(width: Metrics.sidebarMinWidth)
        await show(SidebarUpdatePill(title: String(repeating: "Update Ready ", count: 6), help: "h"), in: view)
        #expect(view.updatePillView.isCompact)
        #expect(view.updatePillView.frame.width == SidebarUpdatePillView.height)
        #expect(view.updatePillView.shownTitle.isEmpty)
    }
}
