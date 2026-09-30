import AppKit
import CmuxNextDesign
import QuartzCore

/// The very subtle machine label of a tab whose terminal runs on another
/// machine (plans/cmux-next/data-model.md 1.2b).
extension TabCell {
    func updateMachineBadge() {
        guard let badge = item.machineBadge, !badge.isEmpty else {
            machineLayer?.removeFromSuperlayer()
            machineLayer = nil
            return
        }
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
        label.foregroundColor = Palette.textTertiary.cgColor
    }

    /// Places the machine badge at the end of the title area when the title
    /// keeps at least a few characters; returns where the title must end.
    func layoutMachineBadge(titleX: CGFloat, titleEnd: CGFloat, midY: CGFloat) -> CGFloat {
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
