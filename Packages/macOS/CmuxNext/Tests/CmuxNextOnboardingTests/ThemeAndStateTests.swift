import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextOnboarding

@Suite struct ThemeAndStateTests {
    @Test func parsesGhosttyThemeFiles() throws {
        let input = try #require(GhosttyThemeFile.parse("""
            # comment
            palette = 0=#45475a
            palette = 1=f38ba8
            palette = 15 = #bac2de
            background = #1e1e2e
            foreground = cdd6f4
            selection-background = #585b70
            cursor-color = #f5e0dc
            """))
        #expect(input.background == ThemeRGB(cssHex: "1e1e2e"))
        #expect(input.foreground == ThemeRGB(cssHex: "#cdd6f4"))
        #expect(input.palette[0] == ThemeRGB(cssHex: "#45475a"))
        #expect(input.palette[1] == ThemeRGB(cssHex: "#f38ba8"))
        #expect(input.palette[15] == ThemeRGB(cssHex: "#bac2de"))
        #expect(input.palette[2] == ThemeInput.ghosttyDefault.palette[2])
        #expect(input.selectionBackground == ThemeRGB(cssHex: "#585b70"))
        #expect(GhosttyThemeFile.parse("palette = 0=#000000") == nil)
    }

    @Test func loadsCuratedThemesInOrderSkippingMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "themes"), withIntermediateDirectories: true)
        try "background = #000000\nforeground = #ffffff".write(to: dir.appending(path: "themes/Nord"), atomically: true, encoding: .utf8)
        try "background = #ffffff\nforeground = #000000".write(to: dir.appending(path: "themes/Rose Pine Dawn"), atomically: true, encoding: .utf8)
        let choices = ThemeChoice.loadCurated(resourcesDirectory: dir.path)
        #expect(choices.map(\.name) == ["Nord", "Rose Pine Dawn"])
        #expect(ThemeChoice.loadCurated(resourcesDirectory: nil).isEmpty)
    }

    @Test func stateFileShowsOnceAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "onboarding-\(UUID().uuidString)/onboarding.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let state = OnboardingStateFile(url: url)
        #expect(state.needsOnboarding())
        try state.markDone(completed: false)
        #expect(!state.needsOnboarding())
        #expect(OnboardingStateFile.live(environment: [OnboardingStateFile.environmentKey: url.path]).url == url)
    }
}
