import AppKit
import CmuxNextDesignTokens

extension WindowMaterialView {
    /// Shows `image` in the art layer. When a picture is shown already, the window is on screen and
    /// Reduce Motion is off, the layer's contents crossfade from it (`MotionFade.wallpaper`, under
    /// the panes' motion switches); otherwise the new picture shows at once. Only the contents
    /// change: the art view's frame, bounds and gravity stay, so nothing moves.
    func crossfadeArt(to image: NSImage) {
        guard let layer = artView.layer, let previous = artImage, previous !== image, !hidesArt,
              window?.isVisible == true || crossfadesOffScreen, !Motion.reduceMotion else { return showArt(image) }
        let from = layer.presentation()?.contents ?? layer.contents ?? previous
        showArt(image)
        Motion.panes.set(layer, "contents", to: image, fade: .wallpaper, from: from)
    }

    /// The id of the picture the art shows (`debug.themes` `backdrop.picture`): a Light and Dark
    /// pair resolved to the appearance it loaded for, a dynamic frame as its moment; empty with none.
    var shownPictureID: String {
        loadedSelection?.resolved(dark: loadedDark).id ?? ""
    }

    /// The theme tint turned by the appearance tuning's hue and scaled by its saturation.
    func tunedTint(_ tint: NSColor, tuning: AppearanceTuning) -> NSColor {
        guard let rgb = tint.usingColorSpace(.deviceRGB) else { return tint }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let shifted = (hue + CGFloat(tuning.hue - 0.5)).truncatingRemainder(dividingBy: 1)
        return NSColor(deviceHue: shifted < 0 ? shifted + 1 : shifted, // colour-allow: the theme tint turned by the tuning's hue, no raw value (moved from WindowMaterialView.swift)
                       saturation: min(max(saturation * CGFloat(tuning.saturation), 0), 1),
                       brightness: brightness,
                       alpha: alpha)
    }
}

extension WindowMaterialView {
    /// The wash over a window that is not key: none while it is key or opaque, else `dim`
    /// (`appearance.inactiveWindowDim`, 0 by default: the same look in front and behind). Glass
    /// needs no wash of its own: it keeps its key look (``ActiveLookGlassEffectView``), and a wash
    /// over it was the frost Leo saw on every app switch (2026-10-26: "i didnt want any glass.
    /// you're frosting the app's background which is pointless?").
    static func inactiveTintAlpha(material: WindowMaterial, isKeyWindow: Bool, dim: CGFloat) -> CGFloat {
        guard material != .opaque, !isKeyWindow else { return 0 }
        return min(max(dim, 0), 1)
    }

    /// Whether `key` (the key window, nil when none) is `window` or a window it owns, through
    /// `owner` (a window's parent or sheet parent).
    static func family<W: AnyObject>(of window: W, holds key: W?, owner: (W) -> W?) -> Bool {
        var next = key
        // Window chains are a few levels deep; the bound guards a cycle.
        for _ in 0..<32 {
            guard let current = next else { return false }
            if current === window { return true }
            next = owner(current)
        }
        return false
    }

    /// A window looks inactive only once its family held the keyboard and then lost it to another
    /// app or another window; its own page windows, popups and sheets never make it look inactive.
    static func looksInactive(appActive: Bool, familyHoldsKey: Bool, familyHeldKey: Bool) -> Bool {
        guard familyHeldKey || (appActive && familyHoldsKey) else { return false }
        return !(appActive && familyHoldsKey)
    }
}
