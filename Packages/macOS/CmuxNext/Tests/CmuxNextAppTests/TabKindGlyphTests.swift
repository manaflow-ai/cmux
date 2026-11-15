import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextTabs
import Testing

/// Tab icons draw at 12 to 20 pt, so a terminal tab shows the bare `>_` (Leo 2026-11-07: "the terminal
/// thing, it should just be the little ... pizza symbol and then the underscore"). Since 2026-11-09 the
/// same bare prompt is `terminal` everywhere, and a browser tab without a favicon draws the outlined
/// globe every other surface draws (Leo: "this icon didnt get drawn or smth", "just draw that
/// basketball").
@MainActor struct TabKindGlyphTests {
    @Test func terminalAndBrowserTabsResolveToTheTabSizeGlyphs() {
        let terminal = TabItemMapping.shared.item(TabModel(TabSnapshot(surface: 1)), fallbackTitle: "Terminal")
        let dead = TabItemMapping.shared.item(TabModel(TabSnapshot(surface: 2, dead: true)), fallbackTitle: "Terminal")
        let browser = TabItemMapping.shared.item(TabModel(TabSnapshot(surface: 3, kind: .browser, url: "https://example.com")),
                                                 fallbackTitle: "Page")
        #expect(terminal.icon == .icon(.tabTerminal))
        #expect(dead.icon == .icon(.tabTerminalDead))
        #expect(browser.icon == .icon(.tabBrowser))
        #expect(TabIcon.terminal == .icon(.tabTerminal) && TabIcon.terminalDead == .icon(.tabTerminalDead) && TabIcon.browser == .icon(.tabBrowser))
    }

    @Test func theTerminalTabGlyphIsThePromptWithoutItsFrame() throws {
        let tab = try #require(IconPack.bundled.drawing(for: .tabTerminal))
        // One open stroke: the chevron and the underscore. No closed shape, so no window frame.
        #expect(tab.line.count == 1)
        #expect(tab.line.allSatisfy { $0.op == .stroke && !$0.d.contains("Z") })
        #expect(Self.subpaths(tab.line) == 2)
        // Every other use draws the same bare prompt.
        let terminal = try #require(IconPack.bundled.drawing(for: .terminal))
        #expect(terminal.line == tab.line)
    }

    @Test func theBrowserTabGlyphIsTheWholeGlobe() throws {
        let tab = try #require(IconPack.bundled.drawing(for: .tabBrowser))
        let globe = try #require(IconPack.bundled.drawing(for: .browser))
        // The ring, the closed meridian lens and the equator: a ball that reads as finished at tab size.
        #expect(tab.line == globe.line)
        #expect(tab.line.filter { $0.d.contains("Z") }.count >= 2, "ring and lens are closed")
    }

    /// Every tab glyph keeps the pack's 1.5 stroke and centres its ink on the 24-unit grid at the
    /// icon size each density draws tabs at.
    @Test(arguments: DensityPreset.allCases)
    func tabGlyphsStayCentredAtEveryDensity(_ preset: DensityPreset) throws {
        let size = preset.tokens.resolveGlyph(compact: MetricTunables.iconSize.compact, comfortable: MetricTunables.iconSize.comfortable)
        for name in [IconName.tabTerminal, .tabTerminalDead, .tabBrowser] {
            let drawing = try #require(IconPack.bundled.drawing(for: name))
            #expect(drawing.line.allSatisfy { $0.width == 1.5 }, "\(name.rawValue)")
            let image = try #require(CGImage.icon(name, size: size, scale: 2, tint: NSColor.black.cgColor))
            let ink = try #require(Self.inkBox(image), "\(name.rawValue) at \(size) pt drew nothing")
            let side = CGFloat(image.width)
            // Within half a grid unit of the centre, and at least 13.5 of the 24 units across.
            #expect(abs(ink.midX - side / 2) <= side / 24 * 0.75, "\(name.rawValue) at \(size) pt: \(ink)")
            #expect(abs(ink.midY - side / 2) <= side / 24 * 0.75, "\(name.rawValue) at \(size) pt: \(ink)")
            #expect(max(ink.width, ink.height) >= side * 13.5 / 24, "\(name.rawValue) at \(size) pt: \(ink)")
        }
    }

    private static func subpaths(_ layers: [IconLayer]) -> Int {
        layers.reduce(0) { $0 + $1.d.filter { $0 == "M" }.count }
    }

    /// The pixel box of every pixel with ink.
    private static func inkBox(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var box: CGRect?
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 24 {
                box = box?.union(CGRect(x: x, y: y, width: 1, height: 1)) ?? CGRect(x: x, y: y, width: 1, height: 1)
            }
        }
        return box
    }
}
