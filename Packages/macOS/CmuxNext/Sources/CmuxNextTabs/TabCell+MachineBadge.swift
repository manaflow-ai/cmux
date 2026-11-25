import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// The small machine label of a tab whose terminal runs on another machine (plans/cmux-next/data-model.md
/// 1.2b): quiet (textTertiary), or the color the person picked for that machine (`appearance.machineColors`).
/// A Cloud chat draws a cloud glyph in that color instead of its lease's name (#45952).
extension TabCell {
    static let machineIconSize: CGFloat = 12

    func updateMachineBadge() {
        guard let badge = item.machineBadge, !badge.isEmpty, item.machineBadgeIcon == nil else {
            machineLayer?.removeFromSuperlayer()
            machineLayer = nil
            updateMachineIcon()
            return
        }
        machineIconLayer?.removeFromSuperlayer()
        machineIconLayer = nil
        let label = machineLayer ?? {
            let label = ChromeTextLayer()
            label.actions = Self.noActions
            label.contentsScale = scale
            layer.addSublayer(label)
            machineLayer = label
            return label
        }()
        label.font = Typography.caption
        label.string = badge
        themeScope.perform { label.foregroundColor = item.machineBadgeColor.cgColor }
    }

    /// The badge as a glyph (`TabItem.machineBadgeIcon`, a Cloud chat's cloud), in the badge's color.
    private func updateMachineIcon() {
        guard item.machineBadgeIcon != nil else {
            machineIconLayer?.removeFromSuperlayer()
            machineIconLayer = nil
            return
        }
        if machineIconLayer == nil {
            let icon = CALayer()
            icon.actions = Self.noActions
            icon.contentsGravity = .resizeAspect
            layer.addSublayer(icon)
            machineIconLayer = icon
        }
        themeScope.perform { applyMachineIcon() }
    }

    /// theme-scoped: callers run it inside `themeScope.perform`.
    func applyMachineIcon() {
        guard let icon = machineIconLayer, let name = item.machineBadgeIcon else { return }
        icon.contentsScale = scale
        icon.contents = TabPackIconCache.shared.image(name: name, tint: item.machineBadgeColor, size: Self.machineIconSize, scale: scale)
    }

    /// Places the machine badge at the end of the title area when the title
    /// keeps at least a few characters; returns where the title must end.
    func layoutMachineBadge(titleX: CGFloat, titleEnd: CGFloat, midY: CGFloat) -> CGFloat {
        if let machineIconLayer {
            let size = Self.machineIconSize
            guard titleEnd - titleX - size - Metrics.space2 >= 48 else {
                machineIconLayer.opacity = 0
                return titleEnd
            }
            machineIconLayer.frame = CGRect(x: pixel(titleEnd - size), y: pixel(midY - size / 2), width: size, height: size)
            machineIconLayer.opacity = 1
            return titleEnd - size - Metrics.space2
        }
        guard let machineLayer else { return titleEnd }
        let font = Typography.caption
        let width = min(ceil((machineLayer.string as NSString).size(withAttributes: [.font: font]).width), 56)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        guard titleEnd - titleX - width - Metrics.space2 >= 64 else {
            machineLayer.opacity = 0
            return titleEnd
        }
        machineLayer.frame = CGRect(x: pixel(titleEnd - width), y: pixel(midY - lineHeight / 2), width: width, height: lineHeight)
        machineLayer.opacity = 1
        return titleEnd - width - Metrics.space2
    }
}

extension TabItem {
    /// The badge's color: the person's pick for the machine as text on the tab
    /// (MachineColor.pickedRowTextColor), from its own name when the badge shows another, else
    /// textTertiary. Theme-scoped: read it inside `themeScope.perform`.
    @MainActor var machineBadgeColor: NSColor {
        MachineColor(name: machineName ?? machineBadge ?? "").pickedRowTextColor ?? Palette.textTertiary
    }
}
