import AppKit
import CmuxFoundation
import CmuxWorkspaces
import SwiftUI
import Testing

@testable import CmuxAppKitSupportUI

@Suite struct DisplayAccessibilityChromeTests {
    // MARK: Reduce Transparency

    @Test func reduceTransparencyReplacesWindowGlassWithOpaqueFill() {
        let glass = makeResolver(opacity: 0.72).current(settings: makeSettings(
            sidebarBlendMode: "behindWindow",
            bgGlassEnabled: true
        ))
        #expect(glass.backdropPlan(
            glassEffectAvailable: true,
            windowBackgroundPolicy: makeWindowBackgroundPolicy()
        ).hostingPhase == .windowGlass)

        let snapshot = makeResolver(opacity: 0.72).current(settings: makeSettings(
            sidebarBlendMode: "behindWindow",
            bgGlassEnabled: true,
            reduceTransparency: true
        ))

        let plan = snapshot.backdropPlan(
            glassEffectAvailable: true,
            windowBackgroundPolicy: makeWindowBackgroundPolicy()
        )
        #expect(plan.hostingPhase == .opaqueWindowFill)
        #expect(plan.windowIsOpaque)
        #expect(plan.glass == nil)
        #expect(!plan.shouldApplyGhosttyCompositorBlur)
        #expect(plan.windowBackgroundColor.alphaComponent == 1)
    }

    @Test func reduceTransparencyMakesTranslucentTerminalWindowOpaque() {
        let settings = makeSettings(sidebarBlendMode: "withinWindow", bgGlassEnabled: false)
        let translucent = makeResolver(opacity: 0.6).current(settings: settings)
        #expect(translucent.backdropPlan(
            glassEffectAvailable: false,
            windowBackgroundPolicy: makeWindowBackgroundPolicy()
        ).hostingPhase == .transparentRootBackdrop)

        let reduced = makeResolver(opacity: 0.6).current(settings: makeSettings(
            sidebarBlendMode: "withinWindow",
            bgGlassEnabled: false,
            reduceTransparency: true
        ))
        let plan = reduced.backdropPlan(
            glassEffectAvailable: false,
            windowBackgroundPolicy: makeWindowBackgroundPolicy()
        )
        #expect(plan.hostingPhase == .opaqueWindowFill)
        #expect(!plan.usesTransparentWindow)
        // The opaque fill is the color the translucent window composited to.
        #expect(plan.windowBackgroundColor.hexString() == reduced.compositedTerminalBackgroundColor.hexString())
    }

    @Test func reduceTransparencyRootBackdropMatchesOpaqueWindowFill() {
        let reduced = makeResolver(opacity: 0.6).current(settings: makeSettings(
            sidebarBlendMode: "withinWindow",
            bgGlassEnabled: false,
            reduceTransparency: true
        ))
        let plan = reduced.backdropPlan(
            glassEffectAvailable: false,
            windowBackgroundPolicy: makeWindowBackgroundPolicy()
        )

        for policy in [reduced.policy(for: .windowRoot), plan.rootPolicy] {
            guard case let .ghosttyTerminalBackdrop(color, opacity, _) = policy else {
                Issue.record("Expected an opaque terminal backdrop")
                continue
            }
            #expect(opacity == 1)
            #expect(color.hexString(includeAlpha: true) == plan.windowBackgroundColor.hexString(includeAlpha: true))
        }
        #expect(
            plan.rootPolicy.hostLayerBackgroundColor?.hexString(includeAlpha: true)
                == plan.windowBackgroundColor.hexString(includeAlpha: true)
        )
    }

    @Test func reduceTransparencyWithinWindowSidebarCompositesOverWindowFill() {
        let reduced = makeResolver(opacity: 0.6).current(settings: makeSettings(
            sidebarBlendMode: "withinWindow",
            sidebarTintOpacity: 0.4,
            bgGlassEnabled: false,
            reduceTransparency: true
        ))
        guard case let .sidebarMaterial(policy) = reduced.policy(for: .leftSidebar) else {
            Issue.record("Expected a sidebar material policy")
            return
        }
        let tint = reduced.sidebarSettings.materialPolicy.tintColor
        let expected = WindowChromeColorResolver().compositedColor(
            tint,
            over: reduced.compositedTerminalBackgroundColor
        )
        #expect(policy.tintColor.hexString(includeAlpha: true) == expected.hexString(includeAlpha: true))
    }

    @Test func reduceTransparencyDropsSidebarMaterialForOpaqueTint() {
        let snapshot = makeResolver(opacity: 1).current(settings: makeSettings(
            sidebarBlendMode: "behindWindow",
            sidebarTintOpacity: 0.4,
            bgGlassEnabled: false,
            reduceTransparency: true
        ))

        guard case let .sidebarMaterial(policy) = snapshot.policy(for: .leftSidebar) else {
            Issue.record("Expected a sidebar material policy")
            return
        }
        #expect(policy.material == nil)
        #expect(!policy.preferLiquidGlass)
        #expect(!policy.usesWindowLevelGlass)
        #expect(policy.opacity == 1)
        #expect(policy.tintColor.alphaComponent == 1)
    }

    @Test func sidebarMaterialIsUnchangedWithoutReduceTransparency() {
        let snapshot = makeResolver(opacity: 1).current(settings: makeSettings(
            sidebarBlendMode: "behindWindow",
            sidebarTintOpacity: 0.4,
            bgGlassEnabled: false
        ))

        guard case let .sidebarMaterial(policy) = snapshot.policy(for: .leftSidebar) else {
            Issue.record("Expected a sidebar material policy")
            return
        }
        #expect(policy.material == .sidebar)
        #expect(abs(policy.tintColor.alphaComponent - 0.4) < 0.001)
    }

    @Test func opaqueMaterialPolicyCompositesTintOverBase() {
        let policy = SidebarBackdropMaterialPolicy(
            material: .sidebar,
            blendingMode: .behindWindow,
            state: .active,
            opacity: 0.8,
            tintColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5),
            cornerRadius: 6,
            preferLiquidGlass: true,
            usesWindowLevelGlass: true
        )

        let opaque = policy.opaque(over: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))

        #expect(opaque.material == nil)
        #expect(opaque.opacity == 1)
        #expect(opaque.cornerRadius == 6)
        #expect(!opaque.preferLiquidGlass)
        #expect(!opaque.usesWindowLevelGlass)
        #expect(opaque.tintColor.alphaComponent == 1)
        #expect(abs(opaque.tintColor.redComponent - 0.5) < 0.001)
        #expect(opaque.tintColor.greenComponent == 0)
        #expect(abs(opaque.tintColor.blueComponent - 0.5) < 0.001)
    }

    // MARK: Increase Contrast

    @Test(arguments: ["#FFFFFF", "#F8F8F2", "#272822", "#000000"])
    func increasedContrastSeparatorStandsFurtherFromBackground(backgroundHex: String) {
        let background = NSColor(hex: backgroundHex) ?? .black
        let resolver = WindowChromeColorResolver()
        let standard = resolver.compositedColor(
            resolver.separatorColor(forChromeBackground: background),
            over: background
        )
        let increased = resolver.compositedColor(
            resolver.separatorColor(forChromeBackground: background, increaseContrast: true),
            over: background
        )

        #expect(distance(increased, background) > distance(standard, background) * 1.5)
    }

    @Test func separatorDefaultIsUnchanged() {
        let separator = WindowChromeColorResolver().separatorColor(
            forChromeBackground: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        )
        #expect(abs(separator.alphaComponent - 0.26) < 0.001)
        #expect(abs(separator.redComponent - 0.70) < 0.001)
    }

    // MARK: Helpers

    private func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let a = lhs.usingColorSpace(.sRGB) ?? lhs
        let b = rhs.usingColorSpace(.sRGB) ?? rhs
        return abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }

    private func makeResolver(opacity: Double) -> WindowAppearanceResolver {
        WindowAppearanceResolver(
            terminalAppearance: WindowTerminalAppearanceSnapshot(
                backgroundColor: NSColor(hex: "#272822") ?? .black,
                backgroundOpacity: opacity,
                backgroundBlur: .disabled,
                usesHostLayerBackground: true
            )
        )
    }

    private func makeSettings(
        sidebarBlendMode: String,
        sidebarTintOpacity: Double = WindowChromeSidebarTintDefaults().opacity,
        bgGlassEnabled: Bool,
        reduceTransparency: Bool = false
    ) -> WindowAppearanceUserSettingsSnapshot {
        WindowAppearanceUserSettingsSnapshot(
            unifySurfaceBackdrops: false,
            colorScheme: .dark,
            sidebarMaterial: WindowChromeSidebarMaterialOption.sidebar.rawValue,
            sidebarBlendMode: sidebarBlendMode,
            sidebarState: WindowChromeSidebarStateOption.followWindow.rawValue,
            sidebarTintHex: WindowChromeSidebarTintDefaults().hex,
            sidebarTintHexLight: nil,
            sidebarTintHexDark: nil,
            sidebarTintOpacity: sidebarTintOpacity,
            sidebarCornerRadius: 0,
            sidebarBlurOpacity: 1,
            bgGlassEnabled: bgGlassEnabled,
            bgGlassTintHex: "#000000",
            bgGlassTintOpacity: 0.03,
            reduceTransparency: reduceTransparency
        )
    }

    private func makeWindowBackgroundPolicy() -> WindowBackgroundPolicy {
        WindowBackgroundPolicy(settings: AccessibilityFakeWindowBackgroundSettings())
    }
}

private struct AccessibilityFakeWindowBackgroundSettings: WindowBackgroundSettingsReading {
    var sidebarBlendModeRawValue = "withinWindow"
    var isBackgroundGlassEnabled = false
}
