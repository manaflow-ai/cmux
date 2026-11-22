import CmuxNextDesignTokens
@testable import CmuxNextDesign
import Testing

/// A button on a popover's glass in a mid-tone theme (Hot Dog Stand's red) has no ink that reads on every ground
/// its inks are fit over: the glass over the theme's own window, the opaque popup, and the glass over a white and a
/// black page. The fit's passes then stopped on a gray between the poles that read on none: the real app's host
/// pressure popover drew Stop at 3.68:1 and Open Agent Activity at 2.66:1, where the theme's black ink read 4.41 and
/// 5.97 (a1275, fleet capture of Hot Dog Stand, 2026-11-21).
@Suite struct CmuxDialogButtonMidToneGlassTests {
    private static let hotDogStand = ThemeTokens.derive(
        from: ThemeInput(background: ThemeRGB(hex: 0xEA3323), foreground: ThemeRGB(hex: 0xFFFFFF)))

    /// How many of `surfaces` `ink` reads on at 4.5:1.
    private static func reads(_ ink: ThemeRGB, on surfaces: [ThemeRGB]) -> Int {
        surfaces.filter { ink.contrast(with: $0) >= CmuxDialogButtonLook.minimumContrast }.count
    }

    @Test(arguments: [CmuxDialogButton.Role.cancel, .normal])
    func aPopoverButtonOnMidToneGlassReadsOnItsOwnGlass(role: CmuxDialogButton.Role) {
        let tokens = Self.hotDogStand
        let look = CmuxDialogButtonLook(role: role, tokens: tokens, card: CmuxDialogButtonLook.menuCardSurfaces(tokens))
        for surface in look.surfaces {
            #expect(look.title.contrast(with: surface) >= CmuxDialogButtonLook.minimumContrast,
                    "\(role) title \(look.title.contrast(with: surface)):1 on \(surface)")
        }
        let own = look.surfaces[0]
        #expect(look.title.contrast(with: own) >= CmuxDialogButtonLook.minimumContrast,
                "\(role) title \(look.title.contrast(with: own)):1 on the glass over the theme's own window")
        // No other ink reads on more of the grounds.
        let best = [ThemeRGB(hex: 0xFFFFFF), ThemeRGB(hex: 0x000000)].map { Self.reads($0, on: look.surfaces) }.max() ?? 0
        #expect(Self.reads(look.title, on: look.surfaces) >= best,
                "\(role) title reads on \(Self.reads(look.title, on: look.surfaces)) of \(look.surfaces.count) grounds, a pole on \(best)")
    }
}
