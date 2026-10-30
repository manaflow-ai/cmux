import AppKit
@testable import CmuxNextDesign
import Testing

/// The overlay surface roles (schemas/surface-roles/surface-roles.json): every popover, menu, card,
/// toast, sheet and tooltip is glass, never opaque (Leo: "I don't like the non-glassness"), and only
/// Reduce Transparency makes one solid.
@MainActor
struct SurfaceRoleTests {
    private static func reduceTransparency(_ on: Bool) -> ReduceTransparency {
        ReduceTransparency(system: { on }, changes: NotificationCenter())
    }

    /// The roles' looks are the ones the toast, dialog and card drew before they moved to the roles.
    @Test func theNeutralLooksKeepTheirValues() {
        #expect(FloatingGlassStyle.toast == FloatingGlassStyle(cornerRadius: 9, darkVeilAlpha: 0.42, lightVeilAlpha: 0.55,
                                                               darkRim: (0.30, 0.06), lightRim: (0.85, 0.10), castsShadow: true))
        #expect(FloatingGlassStyle.dialog == FloatingGlassStyle(cornerRadius: 14, darkVeilAlpha: 0.48, lightVeilAlpha: 0.62,
                                                                darkRim: (0.28, 0.05), lightRim: (0.85, 0.10), castsShadow: true))
        #expect(FloatingGlassStyle.card == FloatingGlassStyle(cornerRadius: 10, darkVeilAlpha: 0.22, lightVeilAlpha: 0.45,
                                                              darkRim: (0.22, 0.04), lightRim: (0.80, 0.08), castsShadow: false))
    }

    /// Each role names its glass: the toast, sheet and card the neutral glass, the rest the theme's.
    @Test func eachRoleHasItsGlass() {
        #expect(SurfaceRole.toast.neutralStyle == .toast)
        #expect(SurfaceRole.sheet.neutralStyle == .dialog)
        #expect(SurfaceRole.card.neutralStyle == .card)
        for role in [SurfaceRole.popover, .menu, .tooltip] {
            #expect(role.neutralStyle == nil)
            #expect(role.tone == .theme)
        }
        #expect(SurfaceRole.toast.tone == .neutral)
        #expect(!SurfaceRole.card.castsShadow)
        #expect(SurfaceRole.toast.cornerRadius == FloatingGlassStyle.toast.cornerRadius)
        #expect(SurfaceRole.popover.cornerRadius == nil)
    }

    /// No role's veil covers what is behind it as a solid card would, in either appearance.
    @Test(arguments: SurfaceRole.allCases)
    func noRoleIsNearOpaque(role: SurfaceRole) {
        guard let style = role.neutralStyle else { return }
        for isDark in [false, true] {
            #expect(style.look(isDark: isDark).veil.alpha < SurfaceRole.nearOpaque, "\(role) isDark \(isDark)")
        }
        #expect(!role.reduceTransparencyFallback.isEmpty)
    }

    /// A role's surface is glass, and solid only under Reduce Transparency.
    @Test(arguments: SurfaceRole.allCases)
    func aRoleSurfaceIsGlassUntilReduceTransparency(role: SurfaceRole) {
        let glass = OverlaySurfaceView(interactive: true, reduceTransparency: Self.reduceTransparency(false), tone: role.tone)
        #expect(glass.material != .opaque)
        #expect(!glass.isCard)
        let solid = OverlaySurfaceView(interactive: true, reduceTransparency: Self.reduceTransparency(true), tone: role.tone)
        #expect(solid.material == .opaque)
        let made = Glass.makeSurface(role, cornerRadius: 6)
        #expect(made.tone == role.tone)
        #expect(made.cornerRadius == 6)
        #expect(!made.isCard)
    }
}
