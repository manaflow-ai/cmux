import AppKit
import CmuxNextDesign
import CmuxNextIcons
import Testing
@testable import CmuxNextHome

/// Home's first-run rows draw from the cmux icon registry at the size of the
/// text beside them.
@MainActor @Suite struct HomeRegistryIconTests {
    @Test func firstRunRowsNameTheirRegistryIcon() {
        let view = HomeFirstRunView()
        #expect(view.terminal.icon == .terminalNew)
        #expect(view.agent.icon == .agentChat)
        #expect(view.suggestion.icon == .agentQuestion)
    }

    @Test func aFirstRunGlyphIsRowSizeAndFollowsTheScale() throws {
        let row = HomeFirstRunRow(title: "Open a terminal", icon: .terminalNew)
        let side = CGFloat.iconRowSize(forLabelPointSize: 13)
        let image = try #require(row.glyph.image)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: side, height: side))
        row.applyScale(1.5)
        #expect(row.glyph.image?.size == NSSize(width: CGFloat.iconRowSize(forLabelPointSize: 19.5), height: CGFloat.iconRowSize(forLabelPointSize: 19.5)))
    }
}
