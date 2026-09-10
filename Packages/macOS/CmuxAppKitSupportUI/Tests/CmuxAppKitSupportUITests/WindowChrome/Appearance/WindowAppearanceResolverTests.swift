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
        #expect(snapshot.resolvedColorScheme == snapshot.chromeColorScheme)
        #expect(snapshot.sidebarSettings.colorScheme == snapshot.resolvedColorScheme)

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

    @Test(arguments: [
        ("#F8F8F2", ColorScheme.light),
        ("#101820", ColorScheme.dark),
    ])
    func resolverUsesOneTerminalSchemeForSeparateSidebar(
        backgroundHex: String,
        expectedScheme: ColorScheme
    ) {
        let resolver = WindowAppearanceResolver(
            terminalAppearance: WindowTerminalAppearanceSnapshot(
                backgroundColor: NSColor(hex: backgroundHex) ?? .black,
                backgroundOpacity: 1,
                backgroundBlur: .disabled,
                usesHostLayerBackground: true
            )
        )
        let snapshot = resolver.current(settings: makeSettings(
            unifySurfaceBackdrops: false,
            sidebarBlendMode: "withinWindow",
            sidebarTintHexDark: "#FF0000",
            bgGlassEnabled: false
        ))

        #expect(snapshot.resolvedColorScheme == expectedScheme)
        #expect(snapshot.chromeColorScheme == expectedScheme)
        #expect(snapshot.sidebarContentColorScheme == expectedScheme)
        #expect(snapshot.sidebarSettings.colorScheme == expectedScheme)
    }

    @Test(arguments: [
        // Opaque themes own their rendered pixels: the terminal scheme stays
        // authoritative even when the ambient window appearance disagrees.
        (ColorScheme.light, ColorScheme.light, 1.0, ColorScheme.light),
        (ColorScheme.light, ColorScheme.dark, 1.0, ColorScheme.light),
        (ColorScheme.dark, ColorScheme.light, 1.0, ColorScheme.dark),
        (ColorScheme.dark, ColorScheme.dark, 1.0, ColorScheme.dark),
        // Translucent themes composite over the ambient window base, so the
        // readable scheme follows the rendered backdrop (issue #10477: a
        // translucent dark theme in a light window renders light chrome).
        (ColorScheme.light, ColorScheme.light, 0.3, ColorScheme.light),
        (ColorScheme.light, ColorScheme.dark, 0.3, ColorScheme.dark),
        (ColorScheme.dark, ColorScheme.light, 0.3, ColorScheme.light),
        (ColorScheme.dark, ColorScheme.dark, 0.3, ColorScheme.dark),
    ])
    func resolverFollowsRenderedBackdropAuthority(
        terminalScheme: ColorScheme,
        ambientScheme: ColorScheme,
        opacity: Double,
        expectedScheme: ColorScheme
    ) {
        let resolver = WindowAppearanceResolver(
            terminalAppearance: WindowTerminalAppearanceSnapshot(
                backgroundColor: NSColor(hex: terminalScheme == .dark ? "#101820" : "#F8F8F2") ?? .black,
                backgroundOpacity: opacity,
                backgroundBlur: .disabled,
                usesHostLayerBackground: true,
                resolvedColorScheme: terminalScheme
            )
        )
        let snapshot = resolver.current(settings: makeSettings(
            unifySurfaceBackdrops: false,
            sidebarBlendMode: "withinWindow",
            bgGlassEnabled: false,
            colorScheme: ambientScheme
        ))

        #expect(snapshot.resolvedColorScheme == expectedScheme)
        #expect(snapshot.chromeColorScheme == expectedScheme)
        #expect(snapshot.sidebarContentColorScheme == expectedScheme)
        #expect(snapshot.sidebarSettings.colorScheme == expectedScheme)
    }

    /// Callers that omit the ambient scheme must not have translucent chrome
    /// resolved against a guessed light window: without an injected ambient
    /// the resolver fails closed to the terminal authority.
    @Test(arguments: [
        ("#101820", ColorScheme.dark),
        ("#F8F8F2", ColorScheme.light),
    ])
    func omittedAmbientSchemeFailsClosedToTerminalAuthority(
        backgroundHex: String,
        terminalScheme: ColorScheme
    ) {
        let resolver = WindowAppearanceResolver(
            terminalAppearance: WindowTerminalAppearanceSnapshot(
                backgroundColor: NSColor(hex: backgroundHex) ?? .black,
                backgroundOpacity: 0.3,
                backgroundBlur: .disabled,
                usesHostLayerBackground: true,
                resolvedColorScheme: terminalScheme
            )
        )
        let snapshot = resolver.currentFromUserDefaults(defaults: UserDefaults(suiteName: "cmux.tests.omitted-ambient")!)

        #expect(snapshot.resolvedColorScheme == terminalScheme)
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
        bgGlassEnabled: Bool,
        colorScheme: ColorScheme = .dark
    ) -> WindowAppearanceUserSettingsSnapshot {
        WindowAppearanceUserSettingsSnapshot(
            unifySurfaceBackdrops: unifySurfaceBackdrops,
            colorScheme: colorScheme,
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
