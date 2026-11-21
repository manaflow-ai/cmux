import Foundation
import Testing
@testable import CmuxFoundation

/// Covers how a stored window background image choice is read and which file
/// it points at.
@Suite("Window background image settings")
struct WindowBackgroundImageSettingsTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    @Test("No stored path means no image")
    func emptyDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "WindowBackgroundImageSettingsTests.empty.\(UUID())"))
        let settings = WindowBackgroundImageSettings.load(from: defaults)
        #expect(settings == .none)
        #expect(!settings.isEnabled)
        #expect(settings.resolvedFileURL(homeDirectory: home) == nil)
    }

    @Test("Stored values round-trip, with opacity clamped and an unknown fit falling back to cover")
    func storedValues() throws {
        let suite = "WindowBackgroundImageSettingsTests.stored.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("  ~/Pictures/wall.jpg \n", forKey: WindowBackgroundImageSettings.pathDefaultsKey)
        defaults.set(1.7, forKey: WindowBackgroundImageSettings.opacityDefaultsKey)
        defaults.set("tile", forKey: WindowBackgroundImageSettings.fitDefaultsKey)

        let settings = WindowBackgroundImageSettings.load(from: defaults)

        #expect(settings.isEnabled)
        #expect(settings.path == "~/Pictures/wall.jpg")
        #expect(settings.opacity == 1)
        #expect(settings.fit == .cover)
        #expect(settings.resolvedFileURL(homeDirectory: home)?.path == "/Users/tester/Pictures/wall.jpg")
    }

    @Test("Non-finite and negative opacity are made safe")
    func opacitySanitizing() {
        #expect(WindowBackgroundImageSettings(path: "/a.png", opacity: -0.5).opacity == 0)
        #expect(WindowBackgroundImageSettings(path: "/a.png", opacity: .nan).opacity == WindowBackgroundImageSettings.defaultOpacity)
    }

    @Test("Only absolute and home-relative paths resolve", arguments: [
        ("/Library/Desktop Pictures/Sky.heic", "/Library/Desktop Pictures/Sky.heic"),
        ("~/wall.png", "/Users/tester/wall.png"),
        ("wall.png", nil),
        ("~", nil),
        ("~other/wall.png", nil),
    ] as [(String, String?)])
    func pathResolution(path: String, expected: String?) {
        let url = WindowBackgroundImageSettings(path: path).resolvedFileURL(homeDirectory: home)
        #expect(url?.path == expected)
    }
}
