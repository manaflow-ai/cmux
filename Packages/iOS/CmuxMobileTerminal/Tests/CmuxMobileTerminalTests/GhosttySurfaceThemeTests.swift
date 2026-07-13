#if canImport(UIKit)
import CMUXMobileCore
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
