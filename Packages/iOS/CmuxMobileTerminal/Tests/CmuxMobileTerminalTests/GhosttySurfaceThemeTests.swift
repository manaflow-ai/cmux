#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import GhosttyKit
import Testing
import UIKit
@testable import CmuxMobileTerminal

@MainActor
@Test func ghosttyThemesStayScopedToTheirSurface() throws {
    let runtime = try GhosttyRuntime.shared()
    let delegate = ThemeTestSurfaceDelegate()
    var light = TerminalTheme.monokai
    light.background = "#f4f0df"
    var custom = TerminalTheme.monokai
    custom.background = "#063f46"
    let lightSurface = GhosttySurfaceView(
        runtime: runtime,
        delegate: delegate,
        terminalTheme: light
    )
    let customSurface = GhosttySurfaceView(
        runtime: runtime,
        delegate: delegate,
        terminalTheme: custom
    )
    defer {
        lightSurface.prepareForDismantle()
        customSurface.prepareForDismantle()
    }

    let lightBackground = lightSurface.configBackgroundColor

    #expect(lightSurface.configBackgroundColor == lightBackground)
    #expect(lightSurface.configBackgroundColor == light.terminalBackgroundUIColor)
    #expect(customSurface.configBackgroundColor == custom.terminalBackgroundUIColor)
}

@MainActor
@Test func accessoryControlsRecolorWithoutRebuilding() {
    let input = TerminalInputTextView()
    let toolbar = input.toolbarView
    let identifiers = [
        "terminal.inputAccessory.composer",
        "terminal.inputAccessory.hideChrome",
        "terminal.inputAccessory.customize",
    ]
    let before = Dictionary(uniqueKeysWithValues: identifiers.compactMap { identifier in
        toolbar.descendant(withAccessibilityIdentifier: identifier).map { (identifier, $0) }
    })
    var light = TerminalTheme.monokai
    light.background = "#f4f0df"
    light.foreground = "#17212b"

    input.terminalTheme = light

    let after = Dictionary(uniqueKeysWithValues: identifiers.compactMap { identifier in
        toolbar.descendant(withAccessibilityIdentifier: identifier).map { (identifier, $0) }
    })
    #expect(before.count == identifiers.count)
    for identifier in identifiers {
        #expect(before[identifier] === after[identifier])
    }
}

@MainActor
@Test func reverseModeOSCResetsUseRawConfigDefaults() async throws {
    let runtime = try GhosttyRuntime.shared()
    let delegate = ThemeTestSurfaceDelegate()
    var rawConfig = TerminalTheme.monokai
    rawConfig.background = "#eeeeee"
    rawConfig.foreground = "#111111"
    rawConfig.palette += Array(
        repeating: "#000000",
        count: TerminalTheme.extendedPaletteCount - rawConfig.palette.count
    )
    rawConfig.palette[200] = "#010203"
    var effectiveChrome = rawConfig
    effectiveChrome.background = rawConfig.foreground
    effectiveChrome.foreground = rawConfig.background
    let view = GhosttySurfaceView(
        runtime: runtime,
        delegate: delegate,
        terminalTheme: effectiveChrome,
        terminalConfigTheme: rawConfig
    )
    defer { view.prepareForDismantle() }
    let resetWhileReversed = Data(
        ("\u{1B}]10;#123456\u{1B}\\" +
            "\u{1B}]11;#654321\u{1B}\\" +
            "\u{1B}]4;200;rgb:ab/cd/ef\u{1B}\\" +
            "\u{1B}[?5h" +
            "\u{1B}]110\u{1B}\\" +
            "\u{1B}]111\u{1B}\\").utf8
    )

    #expect(await view.processOutputAndWait(resetWhileReversed))
    let frame = try exportThemeFrame(from: view)

    #expect(frame.terminalBackground?.lowercased() == rawConfig.foreground.lowercased())
    #expect(frame.terminalForeground?.lowercased() == rawConfig.background.lowercased())
    #expect(frame.terminalConfigTheme?.background.lowercased() == rawConfig.background.lowercased())
    #expect(frame.terminalConfigTheme?.foreground.lowercased() == rawConfig.foreground.lowercased())
    #expect(frame.terminalConfigTheme?.palette[200].lowercased() == rawConfig.palette[200].lowercased())
    #expect(frame.terminalTheme?.palette[200].lowercased() == "#abcdef")
    #expect(view.configBackgroundColor == effectiveChrome.terminalBackgroundUIColor)

    let mirror = GhosttySurfaceView(
        runtime: runtime,
        delegate: delegate,
        terminalTheme: try #require(frame.terminalTheme),
        terminalConfigTheme: try #require(frame.terminalConfigTheme)
    )
    defer { mirror.prepareForDismantle() }

    #expect(await mirror.processOutputAndWait(frame.vtPatchBytes()))
    let mirroredFrame = try exportThemeFrame(from: mirror, surfaceID: "reverse-reset-mirror")
    #expect(mirroredFrame.terminalTheme?.palette[200].lowercased() == "#abcdef")
    #expect(mirroredFrame.terminalConfigTheme?.palette[200].lowercased() == rawConfig.palette[200].lowercased())
}

@MainActor
@Test func semanticCursorConfigAppliesBeforeReplayReset() async throws {
    let runtime = try GhosttyRuntime.shared()
    let delegate = ThemeTestSurfaceDelegate()
    let view = GhosttySurfaceView(runtime: runtime, delegate: delegate)
    defer { view.prepareForDismantle() }
    var semanticConfig = TerminalTheme.monokai
    semanticConfig.foreground = "#123456"
    semanticConfig.cursorColorSemantic = .foreground
    view.terminalConfigTheme = semanticConfig

    #expect(
        await view.processOutputAndWait(
            Data("\u{1B}]112\u{1B}\\".utf8),
            terminalConfigTheme: semanticConfig
        )
    )
    let frame = try exportThemeFrame(from: view, surfaceID: "semantic-cursor-order")

    #expect(frame.terminalConfigTheme?.cursorColorSemantic == .foreground)
    #expect(frame.terminalTheme?.cursor.lowercased() == semanticConfig.foreground.lowercased())
}

@MainActor
@Test func remoteThemeClearsOptionalColorsFromLocalConfig() async throws {
    let runtime = try GhosttyRuntime()
    let localColors = """
    bold-color = #ff0000
    cursor-text = #00ff00
    """
    localColors.withCString { contents in
        "/__cmux_ios__/local-colors.conf".withCString { path in
            ghostty_config_load_string(
                runtime.config,
                contents,
                UInt(localColors.lengthOfBytes(using: .utf8)),
                path
            )
        }
    }
    ghostty_config_finalize(runtime.config)

    let delegate = ThemeTestSurfaceDelegate()
    var remoteTheme = TerminalTheme.monokai
    remoteTheme.foreground = "#123456"
    remoteTheme.boldColor = nil
    remoteTheme.cursorText = nil
    let view = GhosttySurfaceView(
        runtime: runtime,
        delegate: delegate,
        terminalTheme: remoteTheme,
        terminalConfigTheme: remoteTheme
    )
    defer { view.prepareForDismantle() }

    #expect(await view.processOutputAndWait(Data("\u{1B}[1mX".utf8)))
    let frame = try exportThemeFrame(from: view, surfaceID: "local-optional-color-reset")
    let matchingStyle = frame.styles.first(where: { $0.bold })
    let boldStyle = try #require(matchingStyle)

    #expect(boldStyle.foreground?.lowercased() == remoteTheme.foreground.lowercased())
    #expect(frame.terminalConfigTheme?.cursorText == nil)
}

@MainActor
private func exportThemeFrame(
    from view: GhosttySurfaceView,
    surfaceID: String = "reverse-reset-test"
) throws -> MobileTerminalRenderGridFrame {
    let surface = try #require(view.surface)
    let exported = surfaceID.withCString { pointer in
        ghostty_surface_render_grid_json_with_theme(
            surface,
            pointer,
            UInt(surfaceID.utf8.count),
            1,
            0,
            true
        )
    }
    defer { ghostty_string_free(exported) }
    let pointer = try #require(exported.ptr)
    let data = Data(bytes: pointer, count: Int(exported.len))
    return try JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: data)
}

private extension UIView {
    func descendant(withAccessibilityIdentifier identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for subview in subviews {
            if let match = subview.descendant(withAccessibilityIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private final class ThemeTestSurfaceDelegate: GhosttySurfaceViewDelegate {
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}
    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didResize size: TerminalGridSize,
        reportID: UInt64
    ) {}
}
#endif
