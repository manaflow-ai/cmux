import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextUpdater
import CmuxTheme
import Testing

/// Leo, 2026-10-12: every overlay that carries text is the solid popup surface. These had their own
/// glass, vibrancy or a translucent card fill: the Share cmux dialog. (The omnibar's suggestion card
/// has its own color since cx-d0d.102; the refusal pill is a toast now, #19759.)
@MainActor @Suite(.serialized) struct PopupSurfaceCallersTests {
    @Test func theShareDialogIsThePopupSurface() {
        #expect(ShareCmuxView(writeToPasteboard: { _ in }).surface.material == .opaque)
    }

}
