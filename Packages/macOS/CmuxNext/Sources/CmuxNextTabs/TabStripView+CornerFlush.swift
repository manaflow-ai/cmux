public import AppKit
public import CmuxNextDesign

// The flush corner (`chrome.cornerFlush`, Thunderdome r2 A): the selected tab is the content card's
// color and runs down to the strip's bottom, into the card, and the window root learns when the
// selected tab is the strip's first, so the card's corner under it goes square.
extension TabStripView: TabStripCorner {
    public var cornerFrameInWindow: CGRect { convert(bounds, to: nil) }

    public var selectsLeadingTab: Bool { leadsWithSelection }

    public func setRunsIntoCard(_ runs: Bool) {
        guard runs != runsIntoCard else { return }
        runsIntoCard = runs
        needsLayout = true
    }

    public func setTonedInCard(_ toned: Bool) {
        // Unchanged: the chrome redrew (a new shade or contrast), so the tone follows.
        guard toned != tonedInCard else {
            if toned { updateInCardTone() }
            return
        }
        tonedInCard = toned
        needsLayout = true
        if !toned { updateInCardTone() }
    }

    /// Gives every cell the foot below its pill (the selected one draws it) and reports whether the
    /// selected tab is the first. A layout pass: a selection alone calls ``reportCornerLead()``.
    func updateCornerFlush(tabY: CGFloat, tabHeight: CGFloat) {
        // Bottom tabs have no card under them (`CornerFlushChrome.apply`): the selected tab stays a pill.
        // A strip inside the card (a lower split pane's) runs into its pane's content too while the top row's
        // tabs are folders (``setTonedInCard(_:)``), on its own toned row, so every selected tab joins the content.
        let runsDown = isPaneTabRow && (runsIntoCard || tonedInCard) && CornerFlush.current.isOn
            && DesignSettings.shared.tabBarPosition != .bottom
        let foot = runsDown ? max(0, bounds.height - (tabY + tabHeight)) : 0
        for cell in cells.values { cell.cornerFoot = foot }
        reportCornerLead()
    }

    /// A strip inside the card, toned (``tonedInCard``): the frame's shade over its row and the tab row's divider at
    /// its bottom, both less the selected folder tab, as the window's chrome draws them for the top row
    /// (`MainPaneChromeShadeView`), so a lower pane's selected tab reads as the top row's does. Leo, 2026-11-12:
    /// "fixing up the whole, like, polish of the two-tone mode". O(1): only the selected tab is read.
    func updateInCardTone() {
        guard tonedInCard, let host = layer else {
            inCardTone?.shade.path = nil
            inCardTone?.divider.path = nil
            inCardToneDrawn = nil
            return
        }
        let tone: (shade: CAShapeLayer, divider: CAShapeLayer)
        if let made = inCardTone {
            tone = made
        } else {
            tone = (CAShapeLayer(), CAShapeLayer())
            for part in [tone.shade, tone.divider] {
                part.actions = ["path": NSNull(), "fillColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
                host.insertSublayer(part, at: 0)
            }
            inCardTone = tone
        }
        let folder = selectedFolderPath(in: tone.shade)
        let tokens = themeScope.tokens
        let alpha = Metrics.mainPaneChromeShade(isDark: tokens.isDark), strength = Metrics.tabRowDividerStrength
        let ink = themeScope.perform { Palette.chromeDivider }
        // Every strip redraws on each chrome redraw (`markTopRow`), one per strip's report: an unchanged strip
        // stops here, so a resize under Subtle Tone stays O(strips), not O(strips²) path operations.
        // The divider's weight and place as the top row's: a hairline just inside the strip's bottom (flipped: maxY).
        // The weight follows `appearance.borders` (`Borders.width`), so a change of it redraws.
        let weight = Metrics.lineWidth(Metrics.dividerThickness)
        let key = InCardToneKey(bounds: bounds, folder: folder?.boundingBoxOfPath, alpha: alpha, strength: strength,
                                ink: ink, weight: weight)
        guard key != inCardToneDrawn else { return }
        inCardToneDrawn = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        tone.shade.frame = bounds
        tone.divider.frame = bounds
        var shade = CGPath(rect: bounds, transform: nil)
        var line = CGPath(rect: CGRect(x: 0, y: bounds.maxY - weight, width: bounds.width, height: weight), transform: nil)
        if let folder {
            shade = shade.subtracting(folder)
            line = line.subtracting(folder)
        }
        tone.shade.path = shade
        tone.shade.fillColor = NSColor.black.withAlphaComponent(alpha).cgColor
        tone.divider.path = strength > 0 ? line : nil
        tone.divider.fillColor = ink.withAlphaComponent(ink.alphaComponent * strength).cgColor
    }

    /// Reports to the window root whether the selected tab is the strip's first, on its leading edge,
    /// so the card's corner under it squares or rounds in the same pass as the tab's fill. O(1): only
    /// the selected tab is read, so a selection change costs the same at any tab count.
    func reportCornerLead() {
        guard isPaneTabRow else { return }
        // A toned strip inside the card moves its row's hole with the selection too.
        defer { updateInCardTone() }
        let on = CornerFlush.current.isOn
        var leads = false
        if on, tabsClip.frame.minX <= 0.5, let id = model.selectedID, let cell = cells[id], let place = placed[id] {
            let frame = cellFrame(place, isPinned: cell.item.isPinned)
            leads = frame.minX <= 0.5 && frame.maxX > 0.5
        }
        if let id = model.selectedID { cells[id]?.cornerFeetSkipsLeading = leads }
        // While it leads, every layout reports too: the strip may have reached the card's corner since. A
        // strip that moved in the window reports its new place (the chrome checks the tab row is whole).
        let frame = on ? cornerFrameInWindow : nil
        let folder = on ? layer.flatMap { selectedFolderPath(in: $0)?.boundingBoxOfPath } : nil
        guard leads != leadsWithSelection || leads || (on && !reportedCornerFlush) || frame != reportedCornerFrame
            || folder != reportedFolderFrame else { return }
        leadsWithSelection = leads
        reportedCornerFrame = frame
        reportedFolderFrame = folder
        // Not yet in a window root's tree: report again on the next layout.
        reportedCornerFlush = CornerFlushChrome.stripDidChange(self) && on
    }

    /// The selected tab's folder in `target`'s coordinates, clipped to the tabs' visible run
    /// (`TabStripCorner`): a tab scrolled out of view leaves no hole in the chrome's shade.
    public func selectedFolderPath(in target: CALayer) -> CGPath? {
        guard isPaneTabRow, let id = model.selectedID, let cell = cells[id], let path = cell.folderPath(),
              let clip = tabsClip.layer else { return nil }
        let visible = Self.map(path, from: cell.layer, to: clip).intersection(CGPath(rect: clip.bounds, transform: nil))
        guard !visible.isEmpty else { return nil }
        return Self.map(visible, from: clip, to: target)
    }

    /// `path`, in `source`'s coordinates, in `target`'s (one layer tree): the affine map the layers'
    /// geometry gives, a flip between flipped and unflipped views included.
    static func map(_ path: CGPath, from source: CALayer, to target: CALayer) -> CGPath {
        let o = target.convert(CGPoint.zero, from: source)
        let x = target.convert(CGPoint(x: 1, y: 0), from: source)
        let y = target.convert(CGPoint(x: 0, y: 1), from: source)
        var transform = CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
        return path.copy(using: &transform) ?? path
    }
}

/// What a strip's in-card tone was drawn from (``TabStripView/updateInCardTone()``).
struct InCardToneKey: Equatable {
    var bounds: CGRect
    var folder: CGRect?
    var alpha: CGFloat
    var strength: CGFloat
    var ink: NSColor
    var weight: CGFloat
}
