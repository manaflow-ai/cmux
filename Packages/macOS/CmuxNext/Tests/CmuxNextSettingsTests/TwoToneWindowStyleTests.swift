import CmuxNextDesign
import CmuxNextSettings
import Testing

/// The Two-Tone window style (`appearance.chromeStyle` two-tone) keeps the sidebar's edge line: the
/// line between the sidebar and the transcript is not a lines-off choice. Leo 2026-11-12: "in two-tone
/// mode, it, like, the one between the sidebar and the transcript disappears for some reason. So that
/// was the odd bit."
struct TwoToneWindowStyleTests {
    private func parse(_ appearance: [String: JSONValue], sidebar: [String: JSONValue]? = nil) -> CmuxConfigSnapshot {
        var root: [String: JSONValue] = ["appearance": .object(appearance)]
        if let sidebar { root["sidebar"] = .object(sidebar) }
        return CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
    }

    @Test func twoToneShowsTheSidebarsEdgeLine() {
        let snapshot = parse(["chromeStyle": .string("two-tone")])
        #expect(snapshot.chromeStyle == .twoTone)
        #expect(snapshot.sidebarBorder.shows, "Two-Tone hides the line between the sidebar and the transcript")
        #expect(ChromeStyle.twoTone.sidebarSurface == .separate, "Two-Tone keeps its separate sidebar shade")
    }

    /// Only the styles that draw no lines at all (or none on the sidebar by name) hide the edge line.
    @Test(arguments: ChromeStyle.allCases)
    func onlyLinelessStylesHideTheSidebarsEdgeLine(style: ChromeStyle) {
        let lineless: Set<ChromeStyle> = [.bare, .floating, .blocks]
        #expect(parse(["chromeStyle": .string(style.rawValue)]).sidebarBorder.shows == !lineless.contains(style),
                "\(style): the sidebar's edge line is \(lineless.contains(style) ? "shown" : "hidden")")
    }
}
