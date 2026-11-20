import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Lawrence 2026-11-20, two shots of the tab bar's `+ ⌄` and the pane's ⋮: "roundness of this button needs to always be
/// same as roundness of tabs and size of plus button must be same as size of these buttons (watch out for padding)".
/// At every density the tab bar's + (and its ⌄ segment) round exactly as a tab pill does, and the + is the pane ⋮'s
/// square: the same frame, the same hover fill, centered on the tabs, its glyph inside it.
@MainActor @Suite(.serialized, .closesItsWindows)
struct TabBarPlusShapeTests {
    init() { _ = NSApplication.shared }

    private func at(_ preset: DensityPreset, _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.sidebarSections.density, design.sidebarSections.textSize)
        defer { (design.densityTokens, design.sidebarSections.density, design.sidebarSections.textSize) = saved }
        design.densityTokens = preset.tokens
        design.sidebarSections.density = .compact
        design.sidebarSections.textSize = .standard
        try body()
    }

    @Test(arguments: DensityPreset.allCases)
    func thePlusRoundsAsATabAndIsTheMoreButtonsSize(_ preset: DensityPreset) throws {
        try at(preset) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 60), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let model = TabStripModel(tabs: [TabItem(id: TabID("shape-tab"), title: "Tab")], selectedID: TabID("shape-tab"))
            let strip = TabStripView(model: model)
            strip.dragsWindowFromEmptySpace = false
            strip.showsNewTabMenuButton = true
            strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
            window.contentView = strip
            strip.sync(fromModel: true, animating: false)
            strip.layoutSubtreeIfNeeded()
            strip.layoutSubtreeIfNeeded()

            let cell = try #require(strip.cells[TabID("shape-tab")])
            cell.layoutLayers()
            let tabRadius = cell.backgroundLayer.cornerRadius
            #expect(tabRadius == Metrics.tabCornerRadius, "\(preset): the tab pill rounds at the tab token")

            // The pane's ⋮, as a pane's tab row lays it out.
            let toolbar = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 120, height: TabStripView.preferredHeight))
            toolbar.show(more: true, lit: false)
            toolbar.layoutSubtreeIfNeeded()
            let more = toolbar.moreButton
            more.updateLayer()
            let moreRadius = try #require(more.layer?.cornerRadius)

            let plus = strip.newTabButton
            plus.layoutSubtreeIfNeeded()
            let fill = plus.look.fillLayer
            let side = min(fill.bounds.width, fill.bounds.height)
            // The tab's radius, never past a circle on the +'s own square.
            #expect(fill.cornerRadius == min(tabRadius, side / 2),
                    "\(preset): the +'s fill rounds \(fill.cornerRadius), a tab \(tabRadius)")
            #expect(fill.cornerRadius == moreRadius, "\(preset): the + rounds \(fill.cornerRadius), the ⋮ \(moreRadius)")
            #expect(plus.frame.size == more.frame.size, "\(preset): the + is \(plus.frame.size), the ⋮ \(more.frame.size)")
            #expect(fill.bounds.size == more.bounds.size, "\(preset): the +'s fill is \(fill.bounds.size), the ⋮ \(more.bounds.size)")

            // Centered on the tab pill, its glyph whole inside it.
            let pill = strip.convert(cell.frame, from: strip.tabsClip)
            let plusFrame = strip.convert(plus.frame, from: strip.contentView)
            #expect(abs(plusFrame.midY - pill.midY) <= 0.5, "\(preset): the + centers at \(plusFrame.midY), the tab at \(pill.midY)")
            let glyph = plus.look.glyphLayer
            let ink = try #require(glyph.path).boundingBoxOfPath.insetBy(dx: -glyph.lineWidth / 2, dy: -glyph.lineWidth / 2)
            #expect(plus.bounds.contains(ink), "\(preset): the + glyph \(ink) leaves its button \(plus.bounds)")

            // The split look's ⌄ is the same control: the +'s height and the same corner on its trailing side.
            let chooser = strip.newTabMenuButton
            if !chooser.isHidden, chooser.style == .split {
                chooser.isHighlighted = true
                chooser.layoutSubtreeIfNeeded()
                #expect(chooser.frame.height == plus.frame.height, "\(preset): the ⌄ is \(chooser.frame.height) tall, the + \(plus.frame.height)")
                let fills = (chooser.layer?.sublayers ?? []).filter { !$0.isHidden && $0.cornerRadius > 0 }
                for layer in fills {
                    #expect(layer.cornerRadius == fill.cornerRadius, "\(preset): the ⌄ rounds \(layer.cornerRadius), the + \(fill.cornerRadius)")
                }
                chooser.isHighlighted = false
            }
        }
    }

    /// Every look of a tab bar's + rounds as a tab, the lone + (a tab bar without its ⌄) as the split segment. A +
    /// outside a tab bar (the sidebar's, Home's) keeps the proportional corner, never a circle at a large density.
    @Test(arguments: DensityPreset.allCases)
    func everyTabBarPlusLookRoundsAsATab(_ preset: DensityPreset) {
        at(preset) {
            let side = TitlebarBandButton.side
            let bounds = CGRect(x: 0, y: 0, width: side, height: side)
            for segment in [PlusButtonLook.Segment.alone, .leading] {
                let geometry = PlusButtonLook.geometry(in: bounds, segment: segment, hoverStyle: .plate, showsChevron: false,
                                                       roundsAsTabBarControl: true, scale: 2)
                #expect(geometry.cornerRadius == min(Metrics.tabCornerRadius, side / 2), "\(preset) \(segment): \(geometry.cornerRadius)")
                #expect(geometry.fill.size == bounds.size, "\(preset) \(segment): the fill is the button's square")
            }
            let small = CGRect(x: 0, y: 0, width: 20, height: 20)
            let other = PlusButtonLook.geometry(in: small, segment: .alone, hoverStyle: .plate, showsChevron: false, scale: 2)
            #expect(other.cornerRadius == Metrics.buttonCornerRadius(proportionalTo: 20), "\(preset): a sidebar + keeps its corner")
            #expect(other.cornerRadius < 10, "\(preset): a sidebar + is never a circle")
        }
    }
}
