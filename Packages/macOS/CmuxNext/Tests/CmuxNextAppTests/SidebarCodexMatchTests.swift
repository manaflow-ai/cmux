import AppKit
@testable import CmuxTheme
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/39956: at Default density the sidebar draws the Codex desktop sidebar's
/// rows (30 pt, no gap, 8 pt content padding, 10 pt corner; measured in https://github.com/manaflow-ai/cmux/issues/28793),
/// every other density keeps its own; one list is headed "Workspaces"; titles take a softer ink that still reads on
/// every fill; and the neutral fills are Codex's.
@MainActor @Suite(.serialized)
struct SidebarCodexMatchTests {
    static func ws(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    static func machine(_ ids: [String]) -> CmuxNextSidebar.SidebarSection {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: ids.map { .workspace(ws($0)) })
    }

    /// Runs `body` with the app at `density` and the sidebar at `sidebar`, then puts both back.
    static func at<T>(_ density: DensityPreset, sidebar: SidebarDensity = .compact, _ body: () throws -> T) rethrows -> T {
        let (savedTokens, savedSidebar) = (DesignSettings.shared.densityTokens, DesignSettings.shared.sidebarSections.density)
        DesignSettings.shared.densityTokens = density.tokens
        DesignSettings.shared.sidebarSections.density = sidebar
        defer {
            DesignSettings.shared.densityTokens = savedTokens
            DesignSettings.shared.sidebarSections.density = savedSidebar
        }
        return try body()
    }

    // MARK: Geometry

    @Test func defaultDensityRowsAreCodexRows() throws {
        try Self.at(.cozy) {
            let m = SidebarLayoutMetrics.standard
            #expect(m.rowHeight == 30, "Codex's --height-token-nav-row")
            #expect(m.rowSpacing == 2, "2 pt between rows, so two lit fills do not touch")
            #expect(SidebarStyle.contentInset == 8, "Codex's --padding-row-x")
            #expect(SidebarStyle.horizontalInset < SidebarStyle.contentInset, "the fill sits inside the sidebar edge, the title further in")
            #expect(SidebarStyle.rowCornerRadius == 10, "Codex's --radius-token-row")
            // The row keeps Codex's 30 pt; 2 pt between rows.
            let layout = SidebarLayout.make(sections: [Self.machine(["a", "b"])], metrics: m)
            let a = try #require(layout.row(for: .workspace(WorkspaceID("a"))))
            let b = try #require(layout.row(for: .workspace(WorkspaceID("b"))))
            #expect(b.y - a.y == 32)
        }
    }

    @Test(arguments: [DensityPreset.compact, .comfortable])
    func otherDensitiesKeepTheirRows(_ density: DensityPreset) {
        Self.at(density) {
            let m = SidebarLayoutMetrics.standard
            #expect(m.rowSpacing == Metrics.space1, "\(density) keeps its gap")
            #expect(m.rowHeight == SidebarRowTokens.current.rowHeight, "\(density) keeps its row")
            // Outside Default a row's content sits as far inside its fill as its title has room above and below
            // (Lawrence 2026-11-09, "padding on left/bottom/top/right should be even"), not at the outer inset.
            let row = Metrics.sidebarRowHeight + SidebarDensityTokens.textSize.rowStep
            let even = ((row - SidebarStyle.titleFont.capHeight) / 2 * 2).rounded() / 2
            #expect(SidebarStyle.contentInset == even, "\(density) keeps the even content inset")
            #expect(SidebarStyle.rowCornerRadius == Metrics.tabCornerRadius, "\(density) keeps the tab radius")
        }
    }

    @Test(arguments: [SidebarDensity.comfortable, .expanded])
    func theSidebarsOwnDensityKeepsItsRowsAtDefault(_ sidebar: SidebarDensity) {
        Self.at(.cozy, sidebar: sidebar) {
            #expect(!SidebarRowTokens.current.matchesCodex)
            #expect(SidebarLayoutMetrics.standard.rowSpacing == Metrics.space1)
        }
    }

    // MARK: The list heading

    @Test func oneListIsHeadedWorkspaces() throws {
        var o = SidebarLayoutOptions()
        (o.flattensMachines, o.headsWorkspaceList) = (true, true)
        let m = SidebarLayoutMetrics.standard
        let layout = SidebarLayout.make(sections: [Self.machine(["a", "b"])], metrics: m, options: o)
        let heading = try #require(layout.rows.first)
        #expect(heading.key == .listHeader(.workspaces))
        let a = try #require(layout.row(for: .workspace(WorkspaceID("a"))))
        #expect(a.y == heading.maxY + m.rowSpacing, "the first row follows the heading")
        // Off, a filter, or nothing to head: no heading.
        o.headsWorkspaceList = false
        #expect(!SidebarLayout.make(sections: [Self.machine(["a"])], metrics: m, options: o).rows.contains { $0.key == .listHeader(.workspaces) })
        o.headsWorkspaceList = true
        o.filterMatches = [WorkspaceID("a")]
        #expect(!SidebarLayout.make(sections: [Self.machine(["a"])], metrics: m, options: o).rows.contains { $0.key == .listHeader(.workspaces) })
        o.filterMatches = nil
        #expect(!SidebarLayout.make(sections: [Self.machine([])], metrics: m, options: o).rows.contains { $0.key == .listHeader(.workspaces) })
    }

    @Test func headingsAreTheRowSizeAtTheRegularWeight() {
        #expect(SidebarStyle.headerFont.pointSize == SidebarStyle.titleFont.pointSize)
        let weight = (SidebarStyle.headerFont.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        #expect((weight ?? 0) < NSFont.Weight.medium.rawValue, "a heading is not semibold")
    }

    // MARK: Inks and fills

    /// The default dark theme and a light one (Codex's light foreground on white).
    @Test(arguments: [true, false])
    func titlesAreSofterAndStillRead(dark: Bool) {
        let input = dark ? CmuxTheme.ThemeInput.ghosttyDefault
            : CmuxTheme.ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1A1C1F))
        let tokens = ThemeTokens.derive(from: input)
        let bg = tokens.windowBackground.withAlpha(1)
        #expect(tokens.sidebarTitle != tokens.textPrimary, "softer than the primary text")
        #expect(tokens.sidebarTitle.contrast(with: bg) < tokens.textPrimary.contrast(with: bg))
        for fill in [tokens.selectionFill, tokens.pressedFill, tokens.hoverFill] {
            #expect(tokens.sidebarTitle.contrast(with: fill.composited(over: bg)) >= ThemeTokens.minimumTextContrast)
        }
    }

    /// In a see-through window the title still reads over the worst desktop behind it.
    @Test func titlesReadInASeeThroughWindow() {
        var input = CmuxTheme.ThemeInput.ghosttyDefault
        input.background = ThemeRGB(hex: 0x6A6A6A)
        input.foreground = ThemeRGB(hex: 0xFFFFFF)
        input.backgroundOpacity = 0.6
        let tokens = ThemeTokens.derive(from: input)
        let bg = tokens.windowBackground.withAlpha(1)
        for surface in ThemeTokens.seeThroughSurfaces(bg: bg, opacity: 0.6, isDark: tokens.isDark,
                                                      fills: [tokens.pressedFill, tokens.selectionFill]) {
            #expect(tokens.sidebarTitle.contrast(with: surface) >= ThemeTokens.minimumTextContrast
                    || tokens.sidebarTitle == tokens.textPrimary, "softened only as far as it still reads")
        }
    }

    @Test func neutralFillsAreCodexs() {
        let dark = ThemeTokens.derive(from: .ghosttyDefault)
        #expect(dark.isDark)
        #expect(abs(dark.selectionFill.alpha - 0.08) < 0.001)
        #expect(abs(dark.hoverFill.alpha - 0.05) < 0.001)
        #expect(abs(dark.pressedFill.alpha - 0.12) < 0.001)
        #expect(dark.hoverFill.alpha < dark.secondarySelectionFill.alpha)
        #expect(dark.secondarySelectionFill.alpha < dark.selectionFill.alpha)
        #expect(dark.selectionFill.alpha < dark.pressedFill.alpha)
    }
}
