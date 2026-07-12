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

    GhosttyRuntime.applyTheme(light, to: lightSurface)
    let lightBackground = lightSurface.configBackgroundColor
    GhosttyRuntime.applyTheme(custom, to: customSurface)

    #expect(lightSurface.configBackgroundColor == lightBackground)
    #expect(lightSurface.configBackgroundColor == GhosttyRuntime.backgroundUIColor(for: light))
    #expect(customSurface.configBackgroundColor == GhosttyRuntime.backgroundUIColor(for: custom))
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
