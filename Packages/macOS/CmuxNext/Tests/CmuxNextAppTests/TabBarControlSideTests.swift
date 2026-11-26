import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-23 (msg 48160, shots of the tab bar's `+ ⌄ ⋮` beside a browser pane's omnibar ⋮): "the plus button
/// needs to be as tall as the tabs themselves, at all density levels. the 3 dots thing needs to be same size too. the top
/// right more button needs to be same size as the 3 dots button in the omnibar level, like all buttons need to have same
/// derived size, which is same height as the tabs (which derives from density level) and width == height."
///
/// Every button of a pane's tab row (the +, its ⌄, Exit Zoom and pinned tools; the pane's ⋮ went in #53378) and of the
/// browser's toolbar row (its ⋮ among them) is one square, a tab tall, at every density and sidebar row size.
@MainActor @Suite(.serialized, .closesItsWindows)
struct TabBarControlSideTests {
    init() { _ = NSApplication.shared }

    private func at(_ preset: DensityPreset, density: SidebarDensity = .compact, text: SidebarTextSize = .standard,
                    _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.sidebarSections.density, design.sidebarSections.textSize)
        defer { (design.densityTokens, design.sidebarSections.density, design.sidebarSections.textSize) = saved }
        design.densityTokens = preset.tokens
        design.sidebarSections.density = density
        design.sidebarSections.textSize = text
        try body()
    }

    /// The tab row's and the browser toolbar's buttons at the active density: each a tab-tall square.
    private func expectTabTallSquares(_ label: String) throws {
        let tab = Metrics.tabHeight
        #expect(Metrics.tabBarControlSide == tab, "\(label): the tab bar's button side is \(Metrics.tabBarControlSide), a tab is \(tab)")

        // The +, and its ⌄ beside it: a tab tall, the + as wide, both on the tabs' line.
        let model = TabStripModel(tabs: [TabItem(id: TabID("side-tab"), title: "Tab")], selectedID: TabID("side-tab"))
        let strip = TabStripView(model: model)
        strip.showsNewTabMenuButton = true
        strip.frame = CGRect(x: 0, y: 0, width: 600, height: Metrics.tabStripHeight)
        strip.sync(fromModel: true, animating: false)
        strip.layoutSubtreeIfNeeded()
        #expect(strip.metrics.tabHeight == tab)
        let cell = try #require(strip.cells[TabID("side-tab")])
        let pill = strip.convert(cell.frame, from: strip.tabsClip)
        let plus = strip.newTabButton.frame, chevron = strip.newTabMenuButton.frame
        #expect(plus.height == tab && plus.width == tab, "\(label): the + is \(plus.size), want a \(tab) pt square")
        #expect(chevron.height == tab && chevron.minY == plus.minY, "\(label): the ⌄ is \(chevron), the + \(plus)")
        #expect(abs(plus.midY - pill.midY) <= 0.5, "\(label): the + centers at \(plus.midY), the tab at \(pill.midY)")

        // Exit Zoom and a pinned tool, on the tab row's trailing end (the pane's ⋮ went in #53378).
        let pane = PaneToolbarView(frame: CGRect(x: 0, y: 0, width: 400, height: Metrics.tabStripHeight))
        pane.show([PaneToolbarItem(id: "pin", title: "Pin", symbol: "pin", shortcut: nil)], zoomed: true)
        pane.layoutSubtreeIfNeeded()
        for (name, frame) in [("Exit Zoom", pane.zoomButton.frame), ("pinned tool", try #require(pane.buttons.first).frame)] {
            #expect(frame.width == tab && frame.height == tab, "\(label): the pane's \(name) is \(frame.size), want a \(tab) pt square")
        }

        // The browser toolbar's buttons, its ⋮ among them: the tab row's size.
        #expect(OmnibarStyle.buttonSize == tab, "\(label): the omnibar row's buttons are \(OmnibarStyle.buttonSize), want \(tab)")
        #expect(OmnibarStyle.buttonSize == plus.width, "\(label): the omnibar's ⋮ and the tab bar's + differ")
    }

    @Test(arguments: DensityPreset.allCases)
    func everyTabRowButtonIsATabTallSquare(_ preset: DensityPreset) throws {
        try at(preset) { try expectTabTallSquares("\(preset)") }
    }

    /// A taller sidebar row makes taller tabs (`Metrics.chromeRowHeight`); the buttons follow them.
    @Test(arguments: SidebarDensity.allCases)
    func buttonsFollowTheTabsUnderEverySidebarSize(_ density: SidebarDensity) throws {
        for text in SidebarTextSize.allCases {
            try at(.cozy, density: density, text: text) { try expectTabTallSquares("cozy/\(density)/\(text)") }
        }
    }
}
