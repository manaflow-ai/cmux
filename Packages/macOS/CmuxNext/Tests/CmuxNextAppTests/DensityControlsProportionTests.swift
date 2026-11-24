import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

@MainActor @Suite(.serialized, .closesItsWindows)
struct DensityControlsProportionTests {
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

    private func checkButtons(_ buttons: [NSButton], in root: NSView) {
        let shown = buttons.filter { !$0.isHiddenOrHasHiddenAncestor }
        for (index, button) in shown.enumerated() {
            button.layoutSubtreeIfNeeded()
            if button is SidebarIconButton || button is OverflowButton { button.updateLayer() }
            let side = min(button.bounds.width, button.bounds.height)
            #expect(side > 0)
            // A pane's tab-row tool rounds as the tabs, the +, and the ⋮ beside it; the band keeps the proportional corner.
            let tabRow = (button as? TitlebarBandButton)?.roundsAsTabBarControl == true
            #expect(button.layer?.cornerRadius == (tabRow ? Metrics.tabBarControlCornerRadius(fitting: button.bounds.size)
                                                       : Metrics.buttonCornerRadius(proportionalTo: side)))
            #expect((button.layer?.cornerRadius ?? side) < side / 2)
            if let cell = button.cell, button.image != nil {
                let image = cell.imageRect(forBounds: button.bounds)
                #expect(button.bounds.insetBy(dx: -0.5, dy: -0.5).contains(image), "\(type(of: button)): image \(image) in \(button.bounds)")
            }
            let frame = root.convert(button.bounds, from: button)
            for other in shown.dropFirst(index + 1) {
                #expect(!frame.intersects(root.convert(other.bounds, from: other)), "\(type(of: button)) overlaps \(type(of: other))")
            }
        }
    }

    @Test(arguments: DensityPreset.allCases)
    func tabStripControlsFitTheirSlots(_ preset: DensityPreset) throws {
        try at(preset) {
            let model = TabStripModel(tabs: [TabItem(id: TabID("proportion-tab"), title: "Tab")], selectedID: TabID("proportion-tab"))
            let strip = TabStripView(model: model)
            strip.showsNewTabMenuButton = true
            strip.frame = CGRect(x: 0, y: 0, width: 600, height: Metrics.tabStripHeight)
            strip.sync(fromModel: true, animating: false)
            strip.layoutSubtreeIfNeeded()
            let cell = try #require(strip.cells[TabID("proportion-tab")])
            cell.isHovered = true
            cell.layoutLayers()
            let close = try #require(cell.closeButtonRect)
            let plate = try #require(cell.closeBackgroundLayer)
            let glyph = try #require(cell.closeGlyphLayer)
            #expect(plate.cornerRadius == Metrics.buttonCornerRadius(proportionalTo: close.height))
            #expect(close.contains(glyph.frame))
            #expect(!close.intersects(cell.iconLayer.frame))
            // The title layer spans the tab and fades under the x by design; its text must end before the x.
            let textEnd = cell.titleLayer.frame.minX + ceil(("Tab" as NSString).size(withAttributes: [.font: cell.titleFont]).width)
            #expect(textEnd <= close.minX, "\(preset): the title's text ends at \(textEnd), the x starts at \(close.minX)")
            #expect(cell.layer.bounds.contains(close))
            #expect(cell.titleLayer.frame.height <= cell.layer.bounds.height)
            #expect(cell.layer.bounds.contains(cell.iconLayer.frame))
            let plus = strip.newTabButton, menu = strip.newTabMenuButton
            plus.layoutSubtreeIfNeeded()
            menu.layoutSubtreeIfNeeded()
            #expect(!plus.frame.intersects(menu.frame))
            #expect(strip.convert(cell.frame, from: strip.tabsClip).maxX <= plus.frame.minX)
            let fill = plus.look.fillLayer
            #expect(fill.cornerRadius == Metrics.tabBarControlCornerRadius(fitting: fill.bounds.size), "the +, a tab's corner")
            let plusInk = try #require(plus.look.glyphLayer.path).boundingBoxOfPath.insetBy(dx: -plus.look.glyphLayer.lineWidth / 2,
                                                                                       dy: -plus.look.glyphLayer.lineWidth / 2)
            #expect(plus.bounds.contains(plusInk))
            for layer in menu.layer?.sublayers ?? [] where !layer.isHidden && layer.cornerRadius > 0 {
                #expect(layer.cornerRadius == PlusButtonLook.splitCornerRadius, "the ⌄, the +'s corner")
            }
            for layer in menu.layer?.sublayers ?? [] {
                if let glyph = layer as? CAShapeLayer, let path = glyph.path {
                    #expect(menu.bounds.contains(path.boundingBoxOfPath.insetBy(dx: -glyph.lineWidth / 2, dy: -glyph.lineWidth / 2)))
                }
            }
        }
    }

    @Test(arguments: DensityPreset.allCases)
    func titlebarAndPaneButtonsFit(_ preset: DensityPreset) {
        at(preset) {
            let band = TitlebarToolbarBand(frame: CGRect(x: 0, y: 0, width: 400, height: TitlebarBandButton.side))
            band.layoutSubtreeIfNeeded()
            checkButtons([band.sidebarToggle, band.backButton, band.forwardButton], in: band)
            let pane = PaneToolbarView(frame: CGRect(x: 0, y: 0, width: 400, height: Metrics.tabStripHeight))
            pane.show([PaneToolbarItem(id: "split", title: "Split", symbol: "rectangle.split.2x1", shortcut: nil),
                       PaneToolbarItem(id: "pin", title: "Pin", symbol: "pin", shortcut: nil)], zoomed: true)
            pane.layoutSubtreeIfNeeded()
            checkButtons(pane.buttons + [pane.zoomButton], in: pane)
        }
    }

    @Test(arguments: DensityPreset.allCases)
    func browserControlsAndAddressTextFit(_ preset: DensityPreset) throws {
        try at(preset) {
            let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration())
            let pane = BrowserPaneChrome()
            let chrome = pane.bind(tab, state: BrowserChromeTabState())
            chrome.toolbarButtons.pins = { BrowserToolbarButton.allCases.map(\.rawValue) }
            chrome.addressBar.setBookmarkStar(.off)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close(); pane.drop(); tab.close() }
            window.contentView = chrome
            chrome.frame = window.contentLayoutRect
            chrome.layoutSubtreeIfNeeded()
            let buttons = [chrome.backButton, chrome.forwardButton, chrome.reloadButton]
                + chrome.toolbarButtons.subviews.compactMap { $0 as? ChromeIconButton }
            checkButtons(buttons, in: chrome)
            let bar = chrome.addressBar
            let barRadius = try #require(bar.pill.layer?.cornerRadius)
            #expect(abs(barRadius - Metrics.buttonCornerRadius(proportionalTo: bar.bounds.height)) <= 0.5)
            #expect(barRadius < bar.bounds.height / 2)
            let frame = chrome.convert(bar.bounds, from: bar)
            for button in buttons where !button.isHiddenOrHasHiddenAncestor {
                #expect(!frame.intersects(chrome.convert(button.bounds, from: button)))
            }
            let field = bar.field.alignmentRect(forFrame: bar.field.frame)
            #expect(field.minX >= bar.chip.frame.maxX)
            #expect(field.maxX <= bar.bounds.maxX)
            let font = try #require(bar.field.font)
            #expect(font.capHeight <= field.height)
            #expect(bar.bounds.contains(bar.chip.frame))
            bar.chip.layoutSubtreeIfNeeded()
            let chipSide = min(bar.chip.bounds.width, bar.chip.bounds.height)
            #expect(bar.chip.layer?.cornerRadius == Metrics.buttonCornerRadius(proportionalTo: chipSide))
            #expect((bar.chip.layer?.cornerRadius ?? chipSide) < chipSide / 2)
            for image in bar.chip.subviews.compactMap({ $0 as? NSImageView }) {
                #expect(bar.chip.bounds.contains(image.frame))
            }
            // The star's plate is Helium's, a quarter of its side round (Lucas 2026-11-18: "match it 1:1"), and its glyph's
            // ink stays inside it; the glyph's clear margin may pass it.
            let star = bar.starButton
            star.layoutSubtreeIfNeeded()
            let starSide = min(star.bounds.width, star.bounds.height)
            #expect(star.layer?.cornerRadius == OmnibarStyle.starPlateCornerRadius(side: starSide))
            for image in star.subviews.compactMap({ $0 as? NSImageView }) {
                let inset = image.frame.height * (1 - OmnibarMetrics.starInkRatio) / 2
                #expect(star.bounds.contains(image.frame.insetBy(dx: inset, dy: inset)), "\(preset): the star's ink passes its plate")
            }
            if !bar.starButton.isHidden {
                #expect(field.maxX <= bar.convert(bar.starButton.bounds, from: bar.starButton).minX)
            }
        }
    }

    @Test(arguments: DensityPreset.allCases, [SidebarRowCloseSpot.end, .middle, .even])
    func hoveredWorkspaceControlsKeepTheirGap(_ preset: DensityPreset, _ spot: SidebarRowCloseSpot) throws {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.sidebarSections.density, design.sidebarSections.textSize)
        defer { (design.densityTokens, design.sidebarSections.density, design.sidebarSections.textSize) = saved }
        design.densityTokens = preset.tokens
        try SidebarRowCloseSpotTests.withCloseSpot(spot) {
            for density in SidebarDensity.allCases {
                for text in SidebarTextSize.allCases {
                    design.sidebarSections.density = density
                    design.sidebarSections.textSize = text
                    let ws = SidebarWorkspace(id: WorkspaceID("proportion"), title: "Workspace")
                    let height = SidebarDensityTokens.rowHeight
                    let row = SidebarRow(key: .workspace(ws.id), y: 0, height: height, section: .machine(.local), group: nil,
                                         siblingIndex: 0, parentIndex: nil, isLastInGroup: false, isCollapsed: false,
                                         childCount: 0, groupColor: nil)
                    let view = WorkspaceRowView(key: row.key)
                    view.frame = CGRect(x: 0, y: 0, width: 300, height: height)
                    view.configure(ws, row: row)
                    view.onMore = {}
                    view.isHovered = true
                    view.layoutSubtreeIfNeeded()
                    let close = view.closeButton, more = view.moreButton
                    try #require(!close.isHidden && !more.isHidden)
                    let label = "\(preset)/\(density)/\(text)"
                    if spot.atEnd {
                        let proportionalInset = close.frame.width * 3 / 20
                        let resizeInset = SidebarStyle.trailingClearanceEdge + SidebarResizeBand.contentInset - SidebarStyle.rowEdgeGap
                        let largestHit = max(close.frame.width, SidebarStyle.searchHeight)
                        let expectedInset = max(proportionalInset, resizeInset + (largestHit - close.frame.width) / 2)
                        #expect(abs((view.bounds.maxX - close.frame.maxX - expectedInset) / close.frame.width) < 0.01,
                                "\(label): the proportional inset also clears the largest trailing hit target")
                        let column = SidebarStyle.trailingColumnCenterX(rowWidth: view.bounds.width)
                        #expect(abs((close.frame.midX - column) / close.frame.width) < 0.01,
                                "\(label): the close button stays on the shared trailing column")
                    }
                    #expect(!close.frame.intersects(more.frame), "\(label): \(close.frame), \(more.frame)")
                    #expect(abs(close.frame.minX - more.frame.maxX - close.frame.width / 10) < 0.01,
                            "\(label): the hover buttons keep a proportional gap")
                    for button in [close, more] as [NSButton] {
                        #expect(button.frame.width == button.frame.height, "\(label): square controls")
                        #expect(view.bounds.contains(button.frame), "\(label): the button fits its row")
                    }
                    checkButtons([close, more], in: view)
                    #expect(view.title.font.capHeight <= view.title.frame.height)
                }
            }
        }
    }

    @Test(arguments: DensityPreset.allCases)
    func groupHeaderControlsKeepTheirGap(_ preset: DensityPreset) throws {
        try at(preset) {
            let design = DesignSettings.shared
            for density in SidebarDensity.allCases {
                for text in SidebarTextSize.allCases {
                    design.sidebarSections.density = density
                    design.sidebarSections.textSize = text
                    let id = GroupID("proportion-group")
                    let height = SidebarLayoutMetrics.standard.rowHeight
                    let row = SidebarRow(key: .group(id), y: 0, height: height, section: .machine(.local), group: id,
                                         siblingIndex: 0, parentIndex: nil, isLastInGroup: false, isCollapsed: true,
                                         childCount: 1, groupColor: nil)
                    let header = GroupHeaderRowView(key: row.key)
                    header.frame = CGRect(x: 0, y: 0, width: 300, height: height)
                    header.configure(SidebarGroup(id: id, name: "Group", color: .green, isCollapsed: true, workspaces: []), row: row, animated: false)
                    header.onAdd = {}
                    header.isHovered = true
                    header.layoutSubtreeIfNeeded()
                    checkButtons([header.addButton, header.moreButton], in: header)
                    let chevron = try #require(header.debugDisclosure)
                    let frames = [header.addButton.frame, header.moreButton.frame, chevron.frame]
                    for (left, right) in zip(frames, frames.dropFirst()) {
                        #expect(abs(right.minX - left.maxX - SidebarStyle.trailingControlGap) < 0.01)
                    }
                    #expect(frames.allSatisfy { header.bounds.contains($0) })
                }
            }
        }
    }
}
