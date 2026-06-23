import AppKit
import CmuxFoundation
import CmuxWorkspaces
import SwiftUI
import Testing

@testable import CmuxAppKitSupportUI

@Suite struct WindowAppearanceResolverTests {
    @Test func resolverBuildsSnapshotFromInjectedTerminalAppearanceAndSettings() {
        let resolver = WindowAppearanceResolver(
            terminalAppearance: WindowTerminalAppearanceSnapshot(
                backgroundColor: NSColor(hex: "#272822") ?? .black,
                backgroundOpacity: 0.72,
                backgroundBlur: .disabled,
                usesHostLayerBackground: true
            )
        )

        let snapshot = resolver.current(settings: makeSettings(
            unifySurfaceBackdrops: false,
            sidebarBlendMode: "behindWindow",
            sidebarTintHexDark: "#FF0000",
            sidebarTintOpacity: 0.4,
            bgGlassEnabled: true
        ))

        #expect(snapshot.terminalRenderingMode == .windowHostBackdrop)
        #expect(snapshot.terminalBackgroundOpacity == 0.72)
        #expect(snapshot.sidebarContentColorScheme == .dark)

        guard case let .sidebarMaterial(sidebarPolicy) = snapshot.policy(for: .leftSidebar) else {
            Issue.record("Expected separate left sidebar material policy")
            return
        }
        #expect(sidebarPolicy.blendingMode == .behindWindow)
        #expect(sidebarPolicy.tintColor.hexString(includeAlpha: true) == "#FF000066")

        let plan = snapshot.backdropPlan(
            glassEffectAvailable: true,
            windowBackgroundPolicy: makeWindowBackgroundPolicy()
        )
        #expect(plan.hostingPhase == .windowGlass)
        #expect(plan.usesWindowGlass)
        #expect(plan.glass?.style == .regular)
    }

    @Test func ghosttyMacOSGlassStyleForcesClearRootAndTerminalTintedGlass() {
        let resolver = WindowAppearanceResolver(
            terminalAppearance: WindowTerminalAppearanceSnapshot(
                backgroundColor: NSColor(hex: "#272822") ?? .black,
                backgroundOpacity: 1,
                backgroundBlur: .macosGlassClear,
                usesHostLayerBackground: true
            )
        )

        let snapshot = resolver.current(settings: makeSettings(
            unifySurfaceBackdrops: true,
            sidebarBlendMode: "withinWindow",
            bgGlassEnabled: false
        ))

        guard case .clear = snapshot.policy(for: .windowRoot) else {
            Issue.record("Ghostty glass styles should leave the window root clear")
            return
        }
        #expect(snapshot.windowGlassSettings.style == .clear)

        let plan = snapshot.backdropPlan(
            glassEffectAvailable: true,
            windowBackgroundPolicy: makeWindowBackgroundPolicy()
        )
        #expect(plan.hostingPhase == .windowGlass)
        #expect(plan.glass?.tintColor.hexString(includeAlpha: true) == "#272822FF")
    }

    private func makeSettings(
        unifySurfaceBackdrops: Bool,
        sidebarBlendMode: String,
        sidebarTintHexDark: String? = nil,
        sidebarTintOpacity: Double = WindowChromeSidebarTintDefaults().opacity,
        bgGlassEnabled: Bool
    ) -> WindowAppearanceUserSettingsSnapshot {
        WindowAppearanceUserSettingsSnapshot(
            unifySurfaceBackdrops: unifySurfaceBackdrops,
            colorScheme: .dark,
            sidebarMaterial: WindowChromeSidebarMaterialOption.sidebar.rawValue,
            sidebarBlendMode: sidebarBlendMode,
            sidebarState: WindowChromeSidebarStateOption.followWindow.rawValue,
            sidebarTintHex: WindowChromeSidebarTintDefaults().hex,
            sidebarTintHexLight: nil,
            sidebarTintHexDark: sidebarTintHexDark,
            sidebarTintOpacity: sidebarTintOpacity,
            sidebarCornerRadius: 0,
            sidebarBlurOpacity: 1,
            bgGlassEnabled: bgGlassEnabled,
            bgGlassTintHex: "#000000",
            bgGlassTintOpacity: 0.03
        )
    }

    private func makeWindowBackgroundPolicy() -> WindowBackgroundPolicy {
        WindowBackgroundPolicy(settings: FakeWindowBackgroundSettings())
    }
}

private struct FakeWindowBackgroundSettings: WindowBackgroundSettingsReading {
    var sidebarBlendModeRawValue = "withinWindow"
    var isBackgroundGlassEnabled = false
}
