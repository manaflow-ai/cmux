import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextUpdater
import CmuxTheme
import Testing

/// Leo, 2026-10-12: every overlay that carries text was the solid popup surface; on 2026-10-18 the
/// overlay panels went back to this Mac's material (themed glass). The Share cmux dialog pinned the
/// solid surface until Leo, 2026-10-21: "glass is never opaque (the only exception is the Reduce
/// Transparency fallback)". It follows this Mac's material now, with no card fill (#23801: glass, never solid).
/// (The omnibar's suggestion card has its own color since cx-d0d.102; the refusal pill is a toast
/// now, #19759.)
@MainActor @Suite(.serialized) struct PopupSurfaceCallersTests {
    @Test func theShareDialogIsGlassUnlessReduceTransparency() {
        let surface = ShareCmuxView(writeToPasteboard: { _ in }).surface
        #expect(surface.materialOverride == nil)
        #expect(!surface.isCard)
        #expect(surface.material == OverlayMaterial.select(liquidGlassAvailable: Glass.isLiquidGlassAvailable,
                                                          reduceTransparency: ReduceTransparency.shared.isEnabled))
    }
}
