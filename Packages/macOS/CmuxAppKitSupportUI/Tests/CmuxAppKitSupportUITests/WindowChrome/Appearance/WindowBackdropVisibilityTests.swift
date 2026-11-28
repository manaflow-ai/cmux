import AppKit
import CmuxFoundation
import CmuxWorkspaces
import SwiftUI
import Testing

@testable import CmuxAppKitSupportUI

/// Canvas mode decides whether to leave its fills clear from
/// ``WindowAppearanceSnapshot/showsWindowBackdrop(glassEffectAvailable:windowBackgroundPolicy:)``.
/// Split mode shows the backdrop whenever the window plan is not the opaque
/// fill, so each case checks the answer against that same plan.
@Suite struct WindowBackdropVisibilityTests {
    @Test func translucentTerminalShowsBackdrop() {
        let snapshot = makeSnapshot(opacity: 0.6)

        #expect(phase(of: snapshot) == .transparentRootBackdrop)
        #expect(showsBackdrop(snapshot))
    }

    @Test func opaqueTerminalHidesBackdrop() {
        let snapshot = makeSnapshot(opacity: 1)

        #expect(phase(of: snapshot) == .opaqueWindowFill)
        #expect(!showsBackdrop(snapshot))
    }

    @Test func reduceTransparencyHidesBackdropOfTranslucentTerminal() {
        let snapshot = makeSnapshot(opacity: 0.6, reduceTransparency: true)

        #expect(phase(of: snapshot) == .opaqueWindowFill)
        #expect(!showsBackdrop(snapshot))
    }

    @Test func windowGlassShowsBackdropOfOpaqueTerminal() {
        let snapshot = makeSnapshot(opacity: 1, blur: .macosGlassRegular)

        #expect(phase(of: snapshot) == .windowGlass)
        #expect(showsBackdrop(snapshot))
    }

    private func showsBackdrop(_ snapshot: WindowAppearanceSnapshot) -> Bool {
        snapshot.showsWindowBackdrop(
            glassEffectAvailable: true,
            windowBackgroundPolicy: makeWindowBackgroundPolicy()
        )
    }

    private func phase(of snapshot: WindowAppearanceSnapshot) -> WindowBackdropHostingPhase {
        snapshot.backdropPlan(
            glassEffectAvailable: true,
            windowBackgroundPolicy: makeWindowBackgroundPolicy()
        ).hostingPhase
    }

    private func makeSnapshot(
        opacity: Double,
        blur: GhosttyBackgroundBlur = .disabled,
        reduceTransparency: Bool = false
    ) -> WindowAppearanceSnapshot {
        WindowAppearanceResolver(
            terminalAppearance: WindowTerminalAppearanceSnapshot(
                backgroundColor: NSColor(hex: "#272822") ?? .black,
                backgroundOpacity: opacity,
                backgroundBlur: blur,
                usesHostLayerBackground: true
            )
        ).current(settings: WindowAppearanceUserSettingsSnapshot(
            unifySurfaceBackdrops: false,
            colorScheme: .dark,
            sidebarMaterial: WindowChromeSidebarMaterialOption.sidebar.rawValue,
            sidebarBlendMode: "withinWindow",
            sidebarState: WindowChromeSidebarStateOption.followWindow.rawValue,
            sidebarTintHex: WindowChromeSidebarTintDefaults().hex,
            sidebarTintHexLight: nil,
            sidebarTintHexDark: nil,
            sidebarTintOpacity: WindowChromeSidebarTintDefaults().opacity,
            sidebarCornerRadius: 0,
            sidebarBlurOpacity: 1,
            bgGlassEnabled: false,
            bgGlassTintHex: "#000000",
            bgGlassTintOpacity: 0.03,
            reduceTransparency: reduceTransparency
        ))
    }

    private func makeWindowBackgroundPolicy() -> WindowBackgroundPolicy {
        WindowBackgroundPolicy(settings: VisibilityFakeWindowBackgroundSettings())
    }
}

private struct VisibilityFakeWindowBackgroundSettings: WindowBackgroundSettingsReading {
    var sidebarBlendModeRawValue = "withinWindow"
    var isBackgroundGlassEnabled = false
}
