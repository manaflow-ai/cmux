import AppKit
import CmuxFoundation
import CmuxWorkspaces
import SwiftUI
import Testing

@testable import CmuxAppKitSupportUI

/// Covers how a window background image changes the window's backdrop: what
/// the root paints, how the `NSWindow` is configured, and when the image is
/// dropped.
@Suite struct WindowBackgroundImageAppearanceTests {
    private let image = WindowBackgroundImageSettings(path: "~/Pictures/wall.jpg", opacity: 0.3, fit: .contain)

    @Test func imageClearsTheRootSoTheImageLayerShows() {
        let snapshot = resolve(terminalOpacity: 1, backgroundImage: image)

        #expect(snapshot.backgroundImage == image)
        #expect(snapshot.policy(for: .windowRoot).identityComponent == "clear")
        #expect(snapshot.policy(for: .titlebar).identityComponent == "clear")
        #expect(snapshot.policy(for: .terminalCanvas).identityComponent == "clear")
    }

    @Test func imageWindowIsFilledWithTheOpaqueTerminalColorAndKeepsPanesClear() {
        let snapshot = resolve(terminalOpacity: 1, backgroundImage: image)
        let plan = snapshot.backdropPlan(glassEffectAvailable: true, windowBackgroundPolicy: policy())

        #expect(plan.hostingPhase == .transparentRootBackdrop)
        #expect(!plan.windowIsOpaque)
        #expect(plan.windowBackgroundColor.hexString(includeAlpha: true) == "#202830FF")
        #expect(plan.rootPolicy.identityComponent == "clear")
        #expect(!plan.shouldApplyGhosttyCompositorBlur)
        #expect(snapshot.showsWindowBackdrop(glassEffectAvailable: true, windowBackgroundPolicy: policy()))
    }

    @Test func imageReplacesGlassAndDesktopTransparency() {
        let snapshot = resolve(
            terminalOpacity: 0.6,
            blur: .radius(20),
            bgGlassEnabled: true,
            sidebarBlendMode: "behindWindow",
            backgroundImage: image
        )
        let plan = snapshot.backdropPlan(glassEffectAvailable: true, windowBackgroundPolicy: policy())

        #expect(plan.glass == nil)
        #expect(!plan.usesWindowGlass)
        #expect(!plan.shouldApplyGhosttyCompositorBlur)
        #expect(plan.windowBackgroundColor.alphaComponent == 1)
        // Contrast is resolved against the opaque fill the image sits on.
        #expect(snapshot.terminalBackgroundOpacity == 1)
        #expect(snapshot.compositedTerminalBackgroundColor.hexString() == "#202830")
    }

    @Test func reduceTransparencyDropsTheImage() {
        let snapshot = resolve(terminalOpacity: 1, reduceTransparency: true, backgroundImage: image)
        let plan = snapshot.backdropPlan(glassEffectAvailable: true, windowBackgroundPolicy: policy())

        #expect(snapshot.backgroundImage == nil)
        #expect(plan.hostingPhase == .opaqueWindowFill)
        #expect(snapshot.policy(for: .windowRoot).identityComponent != "clear")
    }

    @Test func noImageLeavesTheWindowUnchanged() {
        let withoutFeature = resolve(terminalOpacity: 0.8, backgroundImage: .none)
        let blankPath = resolve(terminalOpacity: 0.8, backgroundImage: WindowBackgroundImageSettings(path: "   "))

        for snapshot in [withoutFeature, blankPath] {
            let plan = snapshot.backdropPlan(glassEffectAvailable: true, windowBackgroundPolicy: policy())
            #expect(snapshot.backgroundImage == nil)
            #expect(snapshot.terminalBackgroundOpacity == 0.8)
            #expect(plan.hostingPhase == .transparentRootBackdrop)
            #expect(plan.shouldApplyGhosttyCompositorBlur)
            #expect(snapshot.policy(for: .windowRoot).identityComponent == WindowBackdropPolicy.ghosttyTerminalBackdrop(
                color: terminalColor,
                opacity: 0.8,
                renderingMode: .windowHostBackdrop
            ).identityComponent)
        }
    }

    @Test func imageChangesTheWindowMutationIdentity() {
        let without = resolve(terminalOpacity: 1, backgroundImage: .none)
        let with = resolve(terminalOpacity: 1, backgroundImage: image)

        #expect(without.appKitWindowMutationID(windowBackgroundPolicy: policy())
            != with.appKitWindowMutationID(windowBackgroundPolicy: policy()))
    }

    @Test func userDefaultsResolutionReadsTheStoredImage() throws {
        let suite = "WindowBackgroundImageAppearanceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/tmp/wall.png", forKey: WindowBackgroundImageSettings.pathDefaultsKey)
        defaults.set(0.4, forKey: WindowBackgroundImageSettings.opacityDefaultsKey)
        defaults.set("stretch", forKey: WindowBackgroundImageSettings.fitDefaultsKey)

        let snapshot = resolver(terminalOpacity: 1, blur: .disabled).currentFromUserDefaults(defaults: defaults)

        #expect(snapshot.backgroundImage == WindowBackgroundImageSettings(path: "/tmp/wall.png", opacity: 0.4, fit: .stretch))
    }

    // MARK: - Helpers

    private let terminalColor = NSColor(srgbRed: 0x20 / 255, green: 0x28 / 255, blue: 0x30 / 255, alpha: 1)

    private func resolver(terminalOpacity: Double, blur: GhosttyBackgroundBlur) -> WindowAppearanceResolver {
        WindowAppearanceResolver(
            terminalAppearance: WindowTerminalAppearanceSnapshot(
                backgroundColor: terminalColor,
                backgroundOpacity: terminalOpacity,
                backgroundBlur: blur,
                usesHostLayerBackground: true
            )
        )
    }

    private func resolve(
        terminalOpacity: Double,
        blur: GhosttyBackgroundBlur = .disabled,
        bgGlassEnabled: Bool = false,
        sidebarBlendMode: String = "withinWindow",
        reduceTransparency: Bool = false,
        backgroundImage: WindowBackgroundImageSettings
    ) -> WindowAppearanceSnapshot {
        resolver(terminalOpacity: terminalOpacity, blur: blur).current(settings: WindowAppearanceUserSettingsSnapshot(
            unifySurfaceBackdrops: true,
            colorScheme: .dark,
            sidebarMaterial: "sidebar",
            sidebarBlendMode: sidebarBlendMode,
            sidebarState: "followWindow",
            sidebarTintHex: "#000000",
            sidebarTintHexLight: nil,
            sidebarTintHexDark: nil,
            sidebarTintOpacity: 0.18,
            sidebarCornerRadius: 0,
            sidebarBlurOpacity: 1,
            bgGlassEnabled: bgGlassEnabled,
            bgGlassTintHex: "#000000",
            bgGlassTintOpacity: 0.03,
            reduceTransparency: reduceTransparency,
            backgroundImage: backgroundImage
        ))
    }

    private func policy() -> WindowBackgroundPolicy {
        WindowBackgroundPolicy(settings: BackgroundImageFakeWindowBackgroundSettings())
    }
}

private struct BackgroundImageFakeWindowBackgroundSettings: WindowBackgroundSettingsReading {
    var sidebarBlendModeRawValue = "behindWindow"
    var isBackgroundGlassEnabled = true
}
