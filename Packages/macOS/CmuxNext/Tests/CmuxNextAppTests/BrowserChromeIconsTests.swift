import AppKit
import CmuxNextIcons
@testable import CmuxNextBrowser
import Foundation
import Testing

/// The browser chrome draws Chrome's own icons (Lawrence 2026-10-19: "for all the back,
/// forward, and refresh icons, and all the extension icons, and all the icons, ideally we can
/// just use the same exact icons that Chrome uses"). Chromium's vector icons are vendored in
/// design/icons/chromium and generated into the pack as `browser.toolbar.*`, `browser.omnibox.*`,
/// `browser.find.*`, `browser.extensions.*` and `browser.tab.*`.
@MainActor @Suite struct BrowserChromeIconsTests {
    /// The pack families generated from Chromium's icons.
    private static let chromiumFamilies = ["browser.toolbar.", "browser.omnibox.", "browser.find.", "browser.extensions.", "browser.tab."]

    private func isChromiumIcon(_ name: IconName) -> Bool {
        Self.chromiumFamilies.contains { name.rawValue.hasPrefix($0) } && IconPack.bundled.drawing(for: name) != nil
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

    /// The icon left of the URL is Chrome's: tune on a secure page, the warning triangle on an
    /// insecure one, the dangerous mark on a broken or flagged one, the magnifier on an empty bar.
    @Test(arguments: [
        PageInfoSiteKind.web(.secure), .web(.insecure), .web(.dangerous), .empty, .extensionPage,
    ])
    func addressBarIconIsChromes(_ kind: PageInfoSiteKind) {
        let site = PageInfoSite(url: URL(string: "https://example.com"), kind: kind)
        let indicator = PageInfoIndicator.resolve(site: site, isFocused: false, editingSymbol: nil)
        #expect(isChromiumIcon(IconName(indicator.symbol)), "\(kind) shows \(indicator.symbol)")
    }
}
