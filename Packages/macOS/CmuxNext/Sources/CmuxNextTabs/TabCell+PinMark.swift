import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// The pin of a pinned tab (Aziz 2026-11-09: "The horizontal tab width shrinks when I pin and it lacks a pin
/// indicator"). A titled pinned tab (`tabs.pinnedStyle` Titled, the default) draws the pin in the trailing
/// cluster, left of the unread or status mark, where an unpinned tab shows its x on hover: a pinned tab never
/// shows an x (Lawrence msg 19392), so the pin takes that place. An icon-only pinned tab (Chrome) draws it on
/// the icon's bottom leading corner, on a disc of the strip's color so it reads over any favicon.
///
/// A pinned tab with no icon of its own already draws the pin as its icon (`iconImage`), so it gets no
/// second one.
extension TabCell {
    /// The trailing pin's glyph, the speaker's size class.
    static let pinMarkSize: CGFloat = 12
    /// The corner pin's disc on an icon-only tab.
    static let pinCornerSize: CGFloat = 11

    /// Whether this tab draws a pin mark: pinned, with an icon that is not itself the pin.
    var drawsPinMark: Bool {
        guard item.isPinned else { return false }
        if case .none = item.icon, item.tint == nil { return false }
        return true
    }

    func updatePinMark() {
        guard drawsPinMark else {
            pinLayer?.removeFromSuperlayer()
            pinDiscLayer?.removeFromSuperlayer()
            pinLayer = nil
            pinDiscLayer = nil
            return
        }
        guard pinLayer == nil else { return }
        let disc = CALayer()
        disc.actions = Self.noActions
        disc.opacity = 0
        layer.addSublayer(disc)
        pinDiscLayer = disc
        let pin = CALayer()
        pin.name = Self.pinMarkName
        pin.actions = Self.noActions
        pin.contentsGravity = .resizeAspect
        pin.opacity = 0
        layer.addSublayer(pin)
        pinLayer = pin
        // `applyItem` colors it next (`applyPinIcon`).
    }

    static let pinMarkName = "tabs.pinMark"

    /// theme-scoped: callers run it inside `themeScope.perform`.
    func applyPinIcon(tint: NSColor) {
        guard let pin = pinLayer else { return }
        pin.contentsScale = scale
        pin.contents = TabPackIconCache.shared.image(name: .statePinned, tint: tint, size: Self.pinMarkSize, scale: scale)
            ?? TabSymbolCache.shared.image(named: "pin.fill", tint: tint, pointSize: Self.pinMarkSize * 0.8,
                                           size: Self.pinMarkSize, scale: scale)
        pinDiscLayer?.backgroundColor = Palette.windowBackground.cgColor
    }

    /// Places the pin at the end of the title area; returns where the title must end. It always draws
    /// while the title does: it says what the tab is, as the state mark says what it needs.
    func layoutTrailingPin(end: CGFloat, midY: CGFloat) -> CGFloat {
        guard let pinLayer else { return end }
        let size = Self.pinMarkSize
        pinLayer.frame = CGRect(x: pixel(end - size), y: pixel(midY - size / 2), width: size, height: size)
        pinLayer.opacity = 1
        pinDiscLayer?.opacity = 0
        return end - size - Metrics.space2
    }

    /// The pin on the icon's bottom leading corner, for a tab that shows no title (the state mark has the
    /// top trailing one).
    func layoutCornerPin(iconFrame: CGRect, visible: Bool) {
        guard let pinLayer else { return }
        let side = Self.pinCornerSize
        let disc = CGRect(x: pixel(iconFrame.minX - Metrics.space1), y: pixel(iconFrame.maxY - side + Metrics.space1),
                          width: side, height: side)
        pinDiscLayer?.frame = disc
        pinDiscLayer?.cornerRadius = side / 2
        pinDiscLayer?.opacity = visible ? 1 : 0
        pinLayer.frame = disc.insetBy(dx: 1, dy: 1)
        pinLayer.opacity = visible ? 1 : 0
    }
}
