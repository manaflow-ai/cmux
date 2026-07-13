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
    #expect(lightSurface.configBackgroundColor == GhosttyRuntime.backgroundUIColor(for: light))
    #expect(customSurface.configBackgroundColor == GhosttyRuntime.backgroundUIColor(for: custom))
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
            "\u{1B}[?5h" +
            "\u{1B}]110\u{1B}\\" +
            "\u{1B}]111\u{1B}\\").utf8
    )

    #expect(await view.processOutputAndWait(resetWhileReversed))
    let frame = try exportThemeFrame(from: view)

    #expect(frame.terminalBackground?.lowercased() == rawConfig.foreground.lowercased())
    #expect(frame.terminalForeground?.lowercased() == rawConfig.background.lowercased())
    #expect(view.configBackgroundColor == GhosttyRuntime.backgroundUIColor(for: effectiveChrome))
}

@MainActor
private func exportThemeFrame(from view: GhosttySurfaceView) throws -> MobileTerminalRenderGridFrame {
    let surface = try #require(view.surface)
    let surfaceID = "reverse-reset-test"
    let exported = surfaceID.withCString { pointer in
        ghostty_surface_render_grid_json(
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
