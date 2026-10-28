import AppKit
import CmuxNextDesign
import QuartzCore

// The lifted tab (a drag): its raised shadow and its fill.
extension TabCell {
    func updateLift() {
        themeScope.perform { backgroundLayer.shadowColor = Palette.shadow.cgColor }
        // The raised elevation step (PopupStyle.elevation2), not a darker drag shadow.
        let elevation = PopupStyle.elevation2
        backgroundLayer.shadowRadius = elevation.layerRadius
        backgroundLayer.shadowOffset = elevation.layerOffset(flipped: true)
        // The pill casts from its outline (`castPillShadow`), as strongly as its lift fill cast before.
        let strength = isLifted ? ShadowOutline.opacity(elevation.alpha, under: liftFill?.cgColor) : 0
        Motion.tabs.set(backgroundLayer, "shadowOpacity", to: strength, fade: .lift)
        // A lift that starts or ends while the width moves casts from the outline of each frame.
        followPillShadow()
        updateStacking()
        if isLifted { titleFade.stopMarquee(animated: false) }
        // The lifted fill reads as solid from the first frame, so nothing it
        // passes over (a group chip) shows through while it would ease in.
        updateColors(animated: !isLifted)
    }

    /// The lifted pill's fill. Keeps the tabs sliding under it quiet: solid when opaque, thicker glass
    /// when translucent.
    var liftFill: NSColor? {
        themeScope.perform {
            Palette.windowBackground.blended(withFraction: 0.08, of: Palette.textPrimary)
                .map { WindowBackdrop.dragPreview(themeScope).dragLiftFill($0) }
        }
    }

    /// The pill casts its shadow from its outline, so a lift renders none of its parts offscreen. A
    /// moving width gives it the outline of each frame (`followPillShadow`).
    func castPillShadow() {
        backgroundLayer.cast(shadowPath: ShadowOutline(size: backgroundLayer.bounds.size, cornerRadius: backgroundLayer.cornerRadius))
    }

    /// Casts from the pill's outline at its model size and, while a width path moves the pill
    /// (`retimeInner`), from the outline of each frame, as long as a shadow shows (a lift, or its fade out).
    func followPillShadow(now: CFTimeInterval = CACurrentMediaTime()) {
        castPillShadow()
        let radius = backgroundLayer.cornerRadius
        backgroundLayer.followShadowPath(now: now) { ShadowOutline(size: $0, cornerRadius: radius).path }
    }
}
