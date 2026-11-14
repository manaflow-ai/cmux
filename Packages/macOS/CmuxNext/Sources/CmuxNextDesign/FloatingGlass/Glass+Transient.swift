import AppKit
import CmuxTheme

extension FloatingGlassStyle {
    /// One veil and rim for floating menus, popovers, palette, toast and sheet bodies.
    /// Tooltips retain their additional contrast-fitted ink/veil; native menus remain system drawn.
    public static var transient: FloatingGlassStyle {
        let material = TransientMaterial.standard
        return FloatingGlassStyle(cornerDepth: 0,
                                  darkVeilAlpha: material.darkVeilAlpha,
                                  lightVeilAlpha: material.lightVeilAlpha,
                                  darkRim: (material.darkRimTop, material.darkRimBottom),
                                  lightRim: (material.lightRimTop, material.lightRimBottom),
                                  castsShadow: true, veilTakesThemeTint: true)
    }
}
