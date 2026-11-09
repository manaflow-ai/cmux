import AppKit
import CmuxNextDesign
import QuartzCore

/// The mark of the agent acting in the tab (cx-gg84), in the agent's presence color at the end of
/// the title, so a background tab shows which agent is in it and that it is acting: a true circle,
/// or, while the agent drives the screen or a browser (`TabPresence.drive`), that glyph breathing
/// slowly (still under Reduce Motion), the same mark as its sidebar row.
extension TabCell {
    /// The drive glyph's side: the audio speaker's, so the trailing cluster keeps one rhythm.
    static let presenceGlyphSize: CGFloat = 11

    func updatePresenceDot() {
        guard let presence = item.presence else {
            presenceLayer?.removeFromSuperlayer()
            presenceLayer = nil
            return
        }
        if presenceLayer == nil {
            let dot = CALayer()
            dot.actions = Self.noActions
            // The drive glyph is a child, so its breath never fights the cell's hiding of the mark (`opacity`).
            let glyph = CALayer()
            glyph.actions = Self.noActions
            glyph.contentsGravity = .resizeAspect
            dot.addSublayer(glyph)
            layer.addSublayer(dot)
            presenceLayer = dot
        }
        presenceLayer?.cornerRadius = presence.drive == nil ? Self.profileDotSize / 2 : 0
        updatePresenceBreath()
        themeScope.perform { applyPresenceDotColor() }
    }

    /// theme-scoped: callers run it inside `themeScope.perform`.
    func applyPresenceDotColor() {
        guard let presenceLayer, let presence = item.presence else { return }
        let color = AgentPresenceColor(key: presence.colorKey).color
        let glyph = presenceGlyph(of: presenceLayer)
        if let drive = presence.drive {
            presenceLayer.backgroundColor = nil
            glyph.contentsScale = scale
            let config = NSImage.SymbolConfiguration(pointSize: Self.presenceGlyphSize, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            glyph.contents = NSImage(systemSymbolName: drive.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)?.layerContents(forContentsScale: scale)
        } else {
            glyph.contents = nil
            presenceLayer.backgroundColor = color.cgColor
        }
    }

    /// The drive glyph breathes (agent work's breath, `MotionLoop.breath`) so the tab reads as live; the
    /// dot and Reduce Motion stay still.
    func updatePresenceBreath() {
        guard let presenceLayer else { return }
        let glyph = presenceGlyph(of: presenceLayer)
        guard item.presence?.drive != nil, Motion.indicators.animatesLoops else {
            glyph.removeAnimation(forKey: "breath")
            return
        }
        guard glyph.animation(forKey: "breath") == nil, let breath = Motion.indicators.breathAnimation(low: 0.5) else { return }
        glyph.add(breath, forKey: "breath")
    }

    /// The mark's glyph child (made with the mark in ``updatePresenceDot()``).
    private func presenceGlyph(of mark: CALayer) -> CALayer {
        mark.sublayers?.first ?? CALayer()
    }

    /// Places the mark at the end of the title area when the title keeps a
    /// few characters; returns where the title must end.
    func layoutPresenceDot(titleX: CGFloat, titleEnd: CGFloat, midY: CGFloat) -> CGFloat {
        guard let presenceLayer else { return titleEnd }
        let size = item.presence?.drive == nil ? Self.profileDotSize : Self.presenceGlyphSize
        guard titleEnd - titleX - size - Metrics.space2 >= 48 else {
            presenceLayer.opacity = 0
            return titleEnd
        }
        // Width equals height and the radius is half of it: a true circle (the dot).
        presenceLayer.frame = CGRect(x: pixel(titleEnd - size), y: pixel(midY - size / 2), width: size, height: size)
        presenceGlyph(of: presenceLayer).frame = presenceLayer.bounds
        presenceLayer.opacity = 1
        return titleEnd - size - Metrics.space2
    }
}
