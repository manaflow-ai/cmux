import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// `experiments.terminalAgentMark` (off by default): the tab strip reads it with its metrics, so flipping the switch
/// redraws live, and the rounded-square image is cached apart from the bare mark.
@MainActor @Suite(.serialized) struct TerminalAgentMarkExperimentTests {
    @Test func metricsFollowTheSwitch() {
        let before = DesignSettings.shared.terminalAgentMarks
        defer { DesignSettings.shared.terminalAgentMarks = before }
        DesignSettings.shared.terminalAgentMarks = false
        #expect(TabStripMetrics().terminalAgentMarks == false)
        DesignSettings.shared.terminalAgentMarks = true
        #expect(TabStripMetrics().terminalAgentMarks == true)
    }

    @Test func tileAndBareMarkAreCachedApart() throws {
        let bare = try #require(TabAgentMarkCache.shared.image(brand: "claude", tint: .labelColor, size: 16, scale: 2))
        let tile = try #require(TabAgentMarkCache.shared.image(brand: "claude", tint: .labelColor, size: 16, scale: 2, terminal: true))
        #expect(bare !== tile)
        // The tile's corner-adjacent edge midpoint is filled; the bare mark leaves it clear.
        func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
            let rep = NSBitmapImageRep(cgImage: image)
            return UInt8(((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255).rounded())
        }
        #expect(alpha(tile, x: tile.width / 2, y: 0) > 0)
        #expect(alpha(bare, x: bare.width / 2, y: 0) == 0)
    }
}
