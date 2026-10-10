import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// The speaker of a browser tab playing sound, crossed out while the tab is
/// muted (Chrome's tab audio indicator, cx-d0d.24). Mute Tab in the tab's
/// menu toggles it.
extension TabCell {
    static let audioIconSize: CGFloat = 12

    func updateAudioBadge() {
        guard item.audio != nil else {
            audioLayer?.removeFromSuperlayer()
            audioLayer = nil
            return
        }
        guard audioLayer == nil else { return }
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
        let name: IconName = item.audio == .muted ? .mediaMuted : .mediaAudio
        icon.contentsScale = scale
        icon.contents = TabPackIconCache.shared.image(name: name, tint: Palette.textSecondary, size: Self.audioIconSize, scale: scale)
    }

    /// Places the speaker at the end of the title area when the title keeps
    /// a few characters; returns where the title must end.
    func layoutAudioBadge(titleX: CGFloat, titleEnd: CGFloat, midY: CGFloat) -> CGFloat {
        guard let audioLayer else { return titleEnd }
        let size = Self.audioIconSize
        guard titleEnd - titleX - size - Metrics.space2 >= 48 else {
            audioLayer.opacity = 0
            return titleEnd
        }
        audioLayer.frame = CGRect(x: pixel(titleEnd - size), y: pixel(midY - size / 2), width: size, height: size)
        audioLayer.opacity = 1
        return titleEnd - size - Metrics.space2
    }
}
