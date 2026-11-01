import AppKit
import CmuxNextIcons
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// The browser chrome draws Chrome's own icons (Lawrence 2026-10-19: "for all the back,
/// forward, and refresh icons, and all the extension icons, and all the icons, ideally we can
/// just use the same exact icons that Chrome uses"). Chromium's vector icons are vendored in
/// design/icons/chromium and generated into the pack as `browser.toolbar.*`, `browser.omnibox.*`,
/// `browser.find.*`, `browser.extensions.*`, `browser.tab.*` and `browser.menu.*`.
@MainActor @Suite(.closesItsWindows) struct BrowserChromeIconsTests {
    /// The pack families generated from Chromium's icons.
    private static let chromiumFamilies = ["browser.toolbar.", "browser.omnibox.", "browser.find.", "browser.extensions.", "browser.tab.", "browser.menu."]

    /// Chrome has no Design mode or Theme toolbar button; those keep cmux's icons.
    private static let cmuxOnlyButtons: Set<String> = ["button:designMode", "button:theme"]

    private func isChromiumIcon(_ name: IconName) -> Bool {
        Self.chromiumFamilies.contains { name.rawValue.hasPrefix($0) }
            && IconPack.bundled.drawing(for: name) != nil
            && IconCatalog.bundled.entry(for: name)?.isChromium == true
    }

    /// Every toolbar button Chrome also has draws Chrome's icon. Design mode and the theme
    /// button are cmux's own (Chrome has neither), so they keep cmux icons.
    @Test(arguments: [BrowserToolbarButton.media, .zoom, .favorites, .downloads, .profile, .devTools, .overflow])
    func toolbarButtonDrawsChromesIcon(_ button: BrowserToolbarButton) {
        let facts = BrowserToolbarFacts(engine: .cef, hostsDevTools: true, zoom: 1.25,
                                        media: BrowserToolbarMedia(sessions: 1))
        let icon = BrowserToolbarPolicy.state(button, facts).icon
        #expect(isChromiumIcon(icon), "\(button) draws \(icon.rawValue)")
    }

    /// Zoom shows Chrome's plus magnifier when zoomed in and its minus one when zoomed out.
    @Test func zoomIconFollowsTheZoomDirection() {
        let zoomedIn = BrowserToolbarPolicy.state(.zoom, BrowserToolbarFacts(engine: .cef, hostsDevTools: true, zoom: 1.5)).icon
        let zoomedOut = BrowserToolbarPolicy.state(.zoom, BrowserToolbarFacts(engine: .cef, hostsDevTools: true, zoom: 0.75)).icon
        #expect(isChromiumIcon(zoomedIn))
        #expect(isChromiumIcon(zoomedOut))
        #expect(zoomedIn != zoomedOut)
    }

    /// Downloads draws Chrome's in-progress arrow while a download runs, as Chrome's button does.
    @Test func downloadsIconShowsARunningDownload() {
        let idle = BrowserToolbarPolicy.state(.downloads, BrowserToolbarFacts(engine: .cef, hostsDevTools: true,
                                                                              downloads: BrowserToolbarDownloads(count: 1))).icon
        let running = BrowserToolbarPolicy.state(.downloads, BrowserToolbarFacts(engine: .cef, hostsDevTools: true,
                                                                                 downloads: BrowserToolbarDownloads(count: 1, inProgress: true))).icon
        #expect(isChromiumIcon(idle) && isChromiumIcon(running))
        #expect(idle != running)
    }

    /// The icon left of the URL is Chrome's: tune on a secure page, the warning triangle on an
    /// insecure one, the dangerous mark on a broken or flagged one, the magnifier on an empty bar.
    @Test(arguments: [
        PageInfoSiteKind.web(.secure), .web(.insecure), .web(.dangerous), .empty, .extensionPage,
    ])
    func addressBarIconIsChromes(_ kind: PageInfoSiteKind) {
        let site = PageInfoSite(url: URL(string: "https://example.com"), kind: kind)
        let indicator = PageInfoIndicator.resolve(site: site, isFocused: false, editingSymbol: nil)
        #expect(isChromiumIcon(IconName(indicator.symbol)), "\(kind) shows \(indicator.symbol)")
        // The chip draws it from the pack, not an SF Symbol of that name.
        #expect(IconCatalog.bundled.name(forSymbol: indicator.symbol) == IconName(indicator.symbol))
    }

    /// The live toolbar of a Chromium tab: Back, Forward, Reload, the Extensions puzzle and every
    /// shown toolbar button draw Chrome's icons, except cmux's own Design mode and Theme buttons.
    @Test func liveToolbarDrawsChromesIcons() {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        tab.showsExtensionToolbar = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.isReleasedWhenClosed = false
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = window.contentLayoutRect
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        let icons = chrome.toolbarReport.icons
        for key in ["back", "reload", "extensions", "button:overflow"] {
            #expect(icons[key] != nil, "\(key) is not shown")
        }
        for (key, icon) in icons where !Self.cmuxOnlyButtons.contains(key) {
            #expect(isChromiumIcon(icon), "\(key) draws \(icon.rawValue)")
        }
    }

    /// The page menu's Translate and Cast rows and an extension without its own image draw
    /// Chrome's icons.
    @Test func pageMenuIconsAreChromes() {
        for symbol in BrowserContextMenuItem.chromeIcons.values {
            #expect(isChromiumIcon(IconName(symbol)), "\(symbol)")
        }
        #expect(isChromiumIcon(IconName(BrowserContextMenuIcon.defaultExtensionSymbol)))
    }

    /// A Chromium icon names its SF Symbol fallback without taking that symbol over: the rest of
    /// the app asking for `chevron.backward` or `xmark` keeps getting cmux's icon.
    @Test func chromiumIconsDoNotClaimTheirFallbackSymbols() {
        for name in IconName.catalog where IconCatalog.bundled.entry(for: name)?.isChromium == true {
            guard let entry = IconCatalog.bundled.entry(for: name), !entry.aliasesSymbol else { continue }
            #expect(IconCatalog.bundled.name(forSymbol: entry.sf) != name, "\(name.rawValue) took over \(entry.sf)")
        }
        #expect(IconCatalog.bundled.name(forSymbol: "xmark") != .browserToolbarStop)
    }

    /// Chromium fills its icons even-odd unless the file says otherwise; the renderer honors the
    /// layer's rule, so a ring drawn as two same-direction squares keeps its hole.
    @Test(arguments: [IconLayer.FillRule.evenodd, .nonzero])
    func fillRuleDecidesTheHole(_ rule: IconLayer.FillRule) throws {
        let ring = IconLayer(d: "M2 2L22 2L22 22L2 22Z M8 8L16 8L16 16L8 16Z", op: .fill, rule: rule)
        let context = try #require(CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.drawIcon([ring], in: CGRect(x: 0, y: 0, width: 24, height: 24), ink: CGColor(gray: 0, alpha: 1))
        let image = try #require(context.makeImage())
        let data = try #require(image.dataProvider?.data as Data?)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { data[y * image.bytesPerRow + x * 4 + 3] }
        #expect(alpha(4, 4) == 255)
        #expect(alpha(12, 12) == (rule == .evenodd ? 0 : 255))
    }

    /// Chrome's Downloads icon is one of the even-odd ones; the pack keeps its rule.
    @Test func downloadsKeepsChromesEvenOddFill() throws {
        let drawing = try #require(IconPack.bundled.drawing(for: .browserToolbarDownloads))
        #expect(drawing.line.allSatisfy { $0.rule == .evenodd })
        #expect(IconPack.bundled.drawing(for: .browserToolbarBack)?.line.allSatisfy { $0.rule == .nonzero } == true)
    }
}
