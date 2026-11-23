import CmuxNextDesign
import CmuxNextSettings
import Testing

/// The Blocks window style (`appearance.chromeStyle` blocks, Leo 2026-11-07): solid blocks of tonal
/// fill with no lines anywhere, so it turns `appearance.borders` to none unless cmux.json sets it.
struct BlocksWindowStyleTests {
    private func parse(_ appearance: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func blocksDrawsNoLines() {
        let snapshot = parse(["chromeStyle": .string("blocks")])
        #expect(snapshot.chromeStyle == .blocks)
        #expect(snapshot.borders == .none, "Blocks still draws borders, hairlines or separators")
        #expect(!snapshot.sidebarBorder.shows, "Blocks shows the sidebar's edge line")
        #expect(ChromeStyle.blocks.floatingPanes && ChromeStyle.blocks.sidebarSurface == .separate,
                "Blocks parts the panes from the chrome by fill: every pane its own block on the shaded chrome")
    }

    @Test func aBordersKeyWinsOverTheStyle() {
        let snapshot = parse(["chromeStyle": .string("blocks"), "borders": .string("default")])
        #expect(snapshot.borders == .default)
    }

    /// The other styles leave `appearance.borders` at its own default.
    @Test(arguments: ChromeStyle.allCases.filter { $0 != .blocks })
    func otherStylesKeepTheLines(style: ChromeStyle) {
        #expect(parse(["chromeStyle": .string(style.rawValue)]).borders == .default, "\(style) turned the lines off")
    }
}
