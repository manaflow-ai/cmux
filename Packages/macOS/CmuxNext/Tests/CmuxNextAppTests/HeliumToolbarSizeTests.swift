import AppKit
@testable import CmuxNextBrowser
import CmuxNextBrowserCore
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import Testing

/// Lucas 2026-11-16: match Helium's toolbar pixel for pixel at Compact (Helium's size): the reload glyph draws 14 px tall,
/// the omnibar's search glyph 12 px and its text's capitals 10 px (with the text smoothing's edge), and every other
/// density scales those by its factor over Compact's 0.9, within a pixel (each box snaps to whole pixels).
@MainActor @Suite(.serialized, .closesItsWindows) struct HeliumToolbarSizeTests {
    @Test(arguments: DensityPreset.allCases)
    func reloadSearchAndTextMatchHeliumScaled(preset: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        let reload = try #require(try SidebarRowGlyphOpticalSizeTests.inkBox(chrome.reloadButton))
        let icon = try #require(chrome.addressBar.chip.subviews.compactMap { $0 as? NSImageView }.first { !$0.isHidden })
        let search = try #require(try SidebarRowGlyphOpticalSizeTests.inkBox(icon))
        let font = try #require(chrome.addressBar.field.font)
        let scale = CGFloat(preset.scaleFactor) / 0.9
        let caps = font.capHeight + 0.14 // what the eye measures: smoothing lights the row above the capitals
        let tolerance: CGFloat = preset == .compact ? 0.5 : 1
        #expect(abs(reload.height - 14 * scale) <= tolerance, "\(preset): the reload glyph is \(reload.height) tall, want \(14 * scale)")
        #expect(abs(search.height - 12 * scale) <= tolerance, "\(preset): the search glyph is \(search.height) tall, want \(12 * scale)")
        #expect(abs(caps - 10 * scale) <= 0.25, "\(preset): the URL's capitals are \(caps) tall, want \(10 * scale)")
    }
}
