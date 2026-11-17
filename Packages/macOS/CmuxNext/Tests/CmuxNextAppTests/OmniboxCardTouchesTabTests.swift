import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lucas 2026-11-14 (Helium's open omnibox): the open suggestion card reaches up from the bar to the tab pills above it,
/// so it touches the tab's bottom edge with no gap and no overlap, at every density. A real tab strip and a real browser
/// chrome stack as a pane stacks them (the strip, then the toolbar at its bottom edge), the card opens, and its top
/// edge must be the first pill's bottom edge, to the device pixel.
@MainActor @Suite(.serialized, .closesItsWindows) struct OmniboxCardTouchesTabTests {
    /// A borderless window (a lower pane's strip), and the window's top row under a minimal titlebar, where the strip
    /// evens its pills between the window's top edge and its own bottom.
    @Test(arguments: DensityPreset.allCases, [false, true])
    func theOpenCardTouchesTheTabAbove(preset: DensityPreset, topRow: Bool) throws {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.tabBarPosition, design.titlebar)
        defer { (design.densityTokens, design.tabBarPosition, design.titlebar) = saved }
        design.densityTokens = preset.tokens
        design.tabBarPosition = .top
        design.titlebar = .minimal
        _ = NSApplication.shared
        let style: NSWindow.StyleMask = topRow ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: style,
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let size = window.contentView?.bounds.size ?? NSSize(width: 1000, height: 600)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        window.contentView = root

        let stripHeight = PaneChromeMetrics.current.resolvedStripHeight(scale: window.backingScaleFactor)
        let items = (0..<2).map { TabItem(id: TabID("tab\($0)"), title: "Example Domain \($0)", icon: .icon(.tabTerminal)) }
        // The second tab is selected: a selected tab runs down into the page card, so the first is a plain pill.
        let strip = TabStripView(model: TabStripModel(tabs: items, selectedID: TabID("tab1")))
        strip.frame = NSRect(x: 0, y: size.height - stripHeight, width: size.width, height: stripHeight)
        root.addSubview(strip)
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - stripHeight)
        root.addSubview(chrome)
        root.layoutSubtreeIfNeeded()
        strip.layoutSubtreeIfNeeded()
        chrome.layoutSubtreeIfNeeded()

        let pill = try #require(strip.firstTabPillFrame, "\(preset): the strip drew no pill")
        let pillBottom = strip.convert(pill, to: nil).minY
        let bar = chrome.addressBar
        let suggestion = BrowserSuggestion(kind: .search, title: "sdsa", detail: "", url: URL(string: "https://example.com/")!, score: 1)
        bar.showRows([suggestion, suggestion], highlighted: 0)
        let card = try #require(bar.panel.cardView.superview, "\(preset): no card")
        card.layoutSubtreeIfNeeded()
        let cardTop = card.convert(card.bounds, to: nil).maxY
        #expect(abs(cardTop - pillBottom) <= 0.01, "\(preset) top row \(topRow): the card's top is \(cardTop), the tab's bottom \(pillBottom)")
    }
}

/// The card reaches up only to a horizontal tab strip right above the toolbar: with the tabs at the bottom, vertical
/// or under the toolbar, the bar heads its pane and the card stays at its top edge (review of the Helium card).
@MainActor @Suite(.serialized, .closesItsWindows) struct OmniboxCardStaysInItsPaneTests {
    @Test(arguments: ["bottom", "vertical", "belowToolbar"])
    func noStripAboveMeansNoReach(_ layout: String) throws {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.tabBarPosition, design.verticalTabs, design.tabBarOrder)
        defer { (design.densityTokens, design.tabBarPosition, design.verticalTabs, design.tabBarOrder) = saved }
        design.densityTokens = DensityPreset.cozy.tokens
        design.tabBarPosition = layout == "bottom" ? .bottom : .top
        design.verticalTabs = layout == "vertical"
        design.tabBarOrder = layout == "belowToolbar" ? .belowToolbar : .aboveToolbar
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        #expect(OmnibarStyle.cardTopOutset(bar: chrome.addressBar) == 0, "\(layout): the card reaches above its pane")
        // With the strip above, it reaches.
        design.tabBarPosition = .top
        design.verticalTabs = false
        design.tabBarOrder = .aboveToolbar
        #expect(OmnibarStyle.cardTopOutset(bar: chrome.addressBar) > 0)
    }
}
