@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTerminal
import Foundation
import Testing

/// The Ghostty config's `unfocused-split-opacity` and `unfocused-split-fill` dim unfocused panes
/// (cx-6so.35, R93): the value a config sets reaches the pane dim, cmux keeps no dim when the
/// config sets none, and Settings' diagnostics stop listing the keys as not applied.
@MainActor struct GhosttyUnfocusedSplitTests {
    private func dim(_ text: String) throws -> UnfocusedPaneDim {
        ThemeBridge.unfocusedPaneDim(try #require(GhosttyUnfocusedSplit.resolved(configText: text)))
    }

    @Test func aConfigWithoutTheKeysLeavesPanesUndimmed() throws {
        #expect(try dim("font-size = 13\n") == UnfocusedPaneDim())
    }

    @Test func theOpacityDimsUnfocusedPanesOverTheThemeBackground() throws {
        let dim = try dim("unfocused-split-opacity = 0.7\n")
        #expect(abs(dim.amount - 0.3) < 0.0001)
        #expect(dim.fill == nil)
    }

    @Test func theFillColorsTheDim() throws {
        let dim = try dim("unfocused-split-opacity = 0.8\nunfocused-split-fill = #102030\n")
        #expect(abs(dim.amount - 0.2) < 0.0001)
        #expect(dim.fill == ThemeRGB(r: 0x10, g: 0x20, b: 0x30))
    }

    @Test func anOpacityBelowGhosttysFloorIsClampedAsInGhostty() throws {
        #expect(abs(try dim("unfocused-split-opacity = 0\n").amount - 0.85) < 0.0001)
    }

    @Test func diagnosticsNoLongerListTheKeysAsNotApplied() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("unfocused-split-\(UUID().uuidString)")
        try "unfocused-split-opacity = 0.7\nunfocused-split-fill = #102030\nsplit-divider-color = #ffffff\n"
            .write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = GhosttyRuntime.shared // runs ghostty_init, which config_new needs
        let names = await GhosttyRuntime.configDiagnostics(configFile: file.path).map(\.name)
        #expect(!names.contains("unfocused-split-opacity"))
        #expect(!names.contains("unfocused-split-fill"))
        #expect(names.contains("split-divider-color"))
    }
}
