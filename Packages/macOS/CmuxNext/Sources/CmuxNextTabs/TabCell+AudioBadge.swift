import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// The speaker of a browser tab playing sound, crossed out while the tab is
/// muted (Chrome's tab audio indicator, cx-d0d.24). A click on it mutes or
/// unmutes the tab (Chrome's alert indicator button,
/// `TabStripIntent.toggleAudioMute`), as Mute Tab in the tab's menu does.
/// It reads as a button (Lawrence 2026-10-19): hover brightens the glyph
/// over the close button's fill, and a press darkens the fill.
extension TabCell {
    static let audioIconSize: CGFloat = 12
    /// The fill's outset around the glyph: the strip's hit slack (`isInAudioButton`).
    static let audioFillOutset: CGFloat = 3

    func updateAudioBadge() {
        guard item.audio != nil else {
            audioLayer?.removeFromSuperlayer()
            audioBackgroundLayer?.removeFromSuperlayer()
            audioLayer = nil
            audioBackgroundLayer = nil
            isAudioHovered = false
            isAudioPressed = false
            return
        }
        guard audioLayer == nil else { return }
        let fill = CALayer()
        fill.cornerCurve = .continuous
        fill.actions = ["backgroundColor": Self.fade, "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        layer.insertSublayer(fill, below: titleLayer)
        audioBackgroundLayer = fill
        let icon = CALayer()
        icon.actions = Self.noActions
        icon.contentsGravity = .resizeAspect
        layer.addSublayer(icon)
        audioLayer = icon
        // `applyItem` colors it next (`applyAudioIcon`).
    }

    /// theme-scoped: callers run it inside `themeScope.perform`.
    func applyAudioIcon() {
        guard let icon = audioLayer else { return }
        let name: IconName = item.audio == .muted ? .browserTabMuted : .browserTabAudio
        icon.contentsScale = scale
        let tint = isAudioHovered || isAudioPressed ? Palette.textPrimary : Palette.textSecondary
        icon.contents = iconCaches.packIcons.image(name: name, tint: tint, size: Self.audioIconSize, scale: scale)
        audioBackgroundLayer?.backgroundColor = ChromeHover.fillColor(.init(hovering: isAudioHovered, pressed: isAudioPressed))?.cgColor
    }

    /// The speaker's frame in this cell's coordinates while it shows (the
    /// mute button's hit area), else nil.
    var audioButtonRect: CGRect? {
        guard let audioLayer, audioLayer.opacity > 0, audioLayer.superlayer != nil else { return nil }
        return audioLayer.frame
    }

    /// Places the speaker at the end of the title area when the title keeps
    /// a few characters; returns where the title must end.
    func layoutAudioBadge(titleX: CGFloat, titleEnd: CGFloat, midY: CGFloat) -> CGFloat {
        guard let audioLayer else { return titleEnd }
        let size = Self.audioIconSize
        guard titleEnd - titleX - size - Metrics.space2 >= 48 else {
            audioLayer.opacity = 0
            audioBackgroundLayer?.opacity = 0
            return titleEnd
        }
        let glyph = CGRect(x: pixel(titleEnd - size), y: pixel(midY - size / 2), width: size, height: size)
        audioLayer.frame = glyph
        audioLayer.opacity = 1
        if let audioBackgroundLayer {
            audioBackgroundLayer.frame = glyph.insetBy(dx: -Self.audioFillOutset, dy: -Self.audioFillOutset)
            audioBackgroundLayer.cornerRadius = max(0, metrics.cornerRadius - Metrics.space1)
            audioBackgroundLayer.opacity = 1
        }
        return titleEnd - size - Metrics.space2
    }
}
