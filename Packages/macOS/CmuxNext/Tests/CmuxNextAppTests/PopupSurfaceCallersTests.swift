import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextUpdater
import CmuxTheme
import Testing

/// Leo, 2026-10-12: every overlay that carries text was the solid popup surface; on 2026-10-18 the
/// overlay panels went back to this Mac's material (themed glass). The Share cmux dialog keeps the
/// solid surface it pins itself. (The omnibar's suggestion card has its own color since cx-d0d.102;
/// the refusal pill is a toast now, #19759.)
@MainActor @Suite(.serialized) struct PopupSurfaceCallersTests {
    @Test func theShareDialogIsThePopupSurface() {
        #expect(ShareCmuxView(writeToPasteboard: { _ in }).surface.material == .opaque)
    }

}
