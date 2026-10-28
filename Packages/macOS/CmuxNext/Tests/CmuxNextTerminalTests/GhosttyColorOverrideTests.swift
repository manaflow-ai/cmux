@testable import CmuxNextTerminal
import Foundation
import Testing

/// Colors the Ghostty config sets itself win over every theme (Ghostty applies the config over
/// the theme), so a cmux theme cannot change them. The Theme section names them, and Let Themes
/// Set Colors comments the lines out.
struct GhosttyColorOverrideTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("color-overrides-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appending(path: "themes"), withIntermediateDirectories: true)
        return url
    }

    @Test func colorsTheConfigSetsAreFoundWithTheirLines() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let theme = dir.appending(path: "themes").appending(path: "Mine")
        try "background = #000000\nforeground = #ffffff\ncursor-color = #ff0000\n".write(to: theme, atomically: true, encoding: .utf8)
        let config = dir.appending(path: "config")
        try "font-size = 12\nbackground = #1e1e2e\nforeground = #e6e6e6\n".write(to: config, atomically: true, encoding: .utf8)
        _ = GhosttyRuntime.shared // runs ghostty_init, which config_new needs
        let found = GhosttyRuntime.colorOverrides(configFile: config.path, theme: theme.path)
        #expect(found.map(\.key) == ["background", "foreground"])
        #expect(found.map(\.line) == [2, 3])
        #expect(found.allSatisfy { URL(fileURLWithPath: $0.file).resolvingSymlinksInPath() == config.resolvingSymlinksInPath() })
    }

    @Test func aConfigThatSetsNoColorsHasNoOverrides() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let theme = dir.appending(path: "themes").appending(path: "Mine")
        try "background = #000000\n".write(to: theme, atomically: true, encoding: .utf8)
        let config = dir.appending(path: "config")
        try "font-size = 12\n".write(to: config, atomically: true, encoding: .utf8)
        _ = GhosttyRuntime.shared
        #expect(GhosttyRuntime.colorOverrides(configFile: config.path, theme: theme.path).isEmpty)
    }

    @Test func letThemesSetColorsCommentsOutEveryLineOfTheKeys() throws {
        let text = "font-size = 12\nbackground = #1e1e2e\n  palette = 0=#000000\npalette = 1=#ff0000\n# background = old\nforeground=#e6e6e6\n"
        let edited = GhosttyColorOverride.commentingOut(["background", "palette"], in: text)
        let marker = GhosttyColorOverride.turnedOffMarker
        #expect(edited == """
        font-size = 12
        \(marker)
        # background = #1e1e2e
        \(marker)
        # palette = 0=#000000
        \(marker)
        # palette = 1=#ff0000
        # background = old
        foreground=#e6e6e6

        """)
    }

    @Test func applyWritesThroughASymlinkAndTheOverrideIsGone() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appending(path: "real-config")
        try "background = #1e1e2e\nfont-size = 12\n".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appending(path: "config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let changed = try GhosttyColorOverride.turnOff([GhosttyColorOverride(key: "background", file: link.path, line: 1)])
        #expect(changed.count == 1)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        let theme = dir.appending(path: "themes").appending(path: "Mine")
        try "background = #000000\n".write(to: theme, atomically: true, encoding: .utf8)
        _ = GhosttyRuntime.shared
        #expect(GhosttyRuntime.colorOverrides(configFile: link.path, theme: theme.path).isEmpty)
    }
}
