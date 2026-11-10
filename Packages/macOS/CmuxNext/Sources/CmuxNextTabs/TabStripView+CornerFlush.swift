public import AppKit
public import CmuxNextDesign

// The flush corner (`chrome.cornerFlush`, Thunderdome r2 A): the selected tab is the content card's
// color and runs down to the strip's bottom, into the card, and the window root learns when the
// selected tab is the strip's first, so the card's corner under it goes square.
extension TabStripView: TabStripCorner {
    public var cornerFrameInWindow: CGRect { convert(bounds, to: nil) }

    public var selectsLeadingTab: Bool { leadsWithSelection }

    /// Gives every cell the foot below its pill (the selected one draws it) and reports whether the
    /// selected tab is the first. A layout pass: a selection alone calls ``reportCornerLead()``.
    /// Tabs at the bottom of the window run into nothing: no foot there.
    func updateCornerFlush(tabY: CGFloat, tabHeight: CGFloat) {
        let on = CornerFlush.current.isOn && DesignSettings.shared.tabBarPosition != .bottom
        let foot = on ? max(0, bounds.height - (tabY + tabHeight)) : 0
        for cell in cells.values { cell.cornerFoot = foot }
        reportCornerLead()
        reportFolder(animated: false, onlyIfMoved: true)
    }

    /// The selected tab's folder (`TabCell+CornerFeet`) while it runs into the card, cut to the part
    /// the strip shows: a tab scrolled partly out of an overflowed strip, or under the pinned tabs, is
    /// clipped by `tabsClip` and `scrollingLayer`, so the shade's hole under it is clipped the same way
    /// and never opens beside the strip. nil when nothing of it shows.
    public var selectedFolder: (path: CGPath, layer: CALayer)? {
        guard let id = model.selectedID, let cell = cells[id], cell.runsIntoCard,
              let folder = cell.cornerFeetLayer, let path = folder.path, let shown = clipped(path, in: folder) else { return nil }
        return (shown, folder)
    }

    /// The selected folder along a move in flight (design/selected-is-foreground.md, motion): the tab's
    /// width keyframes (`TabCell+InnerPath`) and its slot's move (`TabStripMove`, read with `MotionPath`),
    /// at each sample in the folder layer's coordinates at rest, clipped as ``selectedFolder`` is; nil
    /// when nothing moves it. The shade's hole plays these samples, so it moves with the folder.
    public var selectedFolderMotion: FolderMotion? {
        guard let id = model.selectedID, let cell = cells[id], cell.runsIntoCard,
              let folder = cell.cornerFeetLayer, let rest = folder.path, let parent = cell.layer.superlayer else { return nil }
        let now = CACurrentMediaTime()
        let widths = cell.innerPath?.folder.flatMap { $0.times.last.map { $0 > now } == true ? $0 : nil }
        let slot = MotionPath(cell.layer, "position", now: now)
        let slotMoves = slot.isExact && slot.moves(after: now)
        guard widths != nil || slotMoves else { return nil }
        var times = widths?.times.filter { $0 >= now } ?? []
        if times.first != now { times.insert(now, at: 0) }
        if slotMoves, let end = slot.end, end > (times.last ?? now) {
            let last = times.last ?? now
            times += MotionPath.times(from: last, to: end, count: MotionPath.sampleCount(seconds: end - last)).dropFirst()
        }
        let atRest = folder.convert(cell.layer.position, from: parent)
        let paths: [CGPath] = times.map { time in
            let outline = widths?.path(at: time) ?? rest
            let shown = slotMoves ? folder.convert(slot.value(at: time), from: parent) : atRest
            var shift = CGAffineTransform(translationX: shown.x - atRest.x, y: shown.y - atRest.y)
            let moved = outline.copy(using: &shift) ?? outline
            return clipped(moved, in: folder) ?? CGPath(rect: .zero, transform: nil)
        }
        return FolderMotion(times: times, paths: paths)
    }

    /// `path` (in `folder`'s coordinates) cut to what the strip shows of it; nil when nothing shows.
    private func clipped(_ path: CGPath, in folder: CALayer) -> CGPath? {
        var shown = path
        for clip in [scrollingLayer, tabsClip.layer].compactMap({ $0 }) where Self.layer(folder, isInside: clip) {
            let visible = clip.convert(clip.bounds, to: folder)
            // The usual case, a folder wholly shown, costs a rect compare, not a path intersection.
            if !visible.contains(shown.boundingBoxOfPath) {
                shown = shown.intersection(CGPath(rect: visible, transform: nil))
            }
        }
        return shown.isEmpty ? nil : shown
    }

    private static func layer(_ layer: CALayer, isInside ancestor: CALayer) -> Bool {
        var next = layer.superlayer
        while let current = next {
            if current === ancestor { return true }
            next = current.superlayer
        }
        return false
    }

    /// Tells the window chrome where the selected folder tab is (design/selected-is-foreground.md): on
    /// the top row the frame's shade cuts it away; inside the card this strip draws the chrome's shade
    /// itself (a band under its tabs) and cuts the folder out of that. `animated`: a selection change,
    /// faded with the tabs. `onlyIfMoved`: a layout pass, which reports only a folder that moved, so a
    /// frame pass costs one path compare. O(1) in the tab count: only the selected tab is read.
    func reportFolder(animated: Bool, onlyIfMoved: Bool = false) {
        let folder = selectedFolder
        let inStrip = layer.flatMap { own in folder.map { own.converted($0.path, from: $0.layer) } }
        let place = cornerFrameInWindow, band = cornerChrome?.bandShade(for: self) ?? 0
        let shown = isShownInWindow && CornerFlush.current.isOn
        // A strip still without its chrome (new, or just moved into a window) looks it up, so its band appears.
        if onlyIfMoved, let last = reportedFolder, last.path == inStrip, last.frame == place, last.band == band,
           cornerChrome != nil || !shown { return }
        reportedFolder = (inStrip, place, band)
        let chrome = shown ? CornerFlushChrome.chrome(of: self) : nil
        if let old = cornerChrome, old !== chrome { old.folderDidChange(self, animated: false, gone: true) }
        cornerChrome = chrome
        let band = chrome?.folderDidChange(self, animated: animated) ?? 0
        applyCornerBand(band, animated: animated)
    }

    /// The chrome's shade under the tabs of a strip inside the content card (design/selected-is-foreground.md):
    /// every strip is chrome, so its selected folder tab, in the content's surface, stands out of it, with
    /// the band cut away under the folder. O(1): one layer the strip's bounds wide, below every tab.
    func applyCornerBand(_ shade: CGFloat, animated: Bool) {
        guard shade > 0 else {
            cornerBandShade = 0
            cornerBandLayer?.isHidden = true
            return
        }
        let band: CALayer
        let holes: ChromeShadeHoles
        if let made = cornerBandLayer, let madeHoles = cornerBandHoles {
            band = made
            holes = madeHoles
        } else {
            band = CALayer()
            band.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
            holes = ChromeShadeHoles()
            band.mask = holes.mask
            layer?.insertSublayer(band, at: 0)
            cornerBandLayer = band
            cornerBandHoles = holes
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.frame = bounds
        band.isHidden = false
        if shade != cornerBandShade || band.backgroundColor == nil {
            cornerBandShade = shade
            band.backgroundColor = NSColor.black.withAlphaComponent(shade).cgColor
        }
        CATransaction.commit()
        holes.layout(bounds: band.bounds)
        let selected = selectedFolder
        let folder = selected.map { band.converted($0.path, from: $0.layer) }
        let motion = animated ? nil : selected.flatMap { shown in selectedFolderMotion?.map { band.converted($0, from: shown.layer) } }
        holes.set(ObjectIdentifier(self), path: folder, animated: animated, motion: motion)
    }

    /// Reports to the window root whether the selected tab is the strip's first, on its leading edge,
    /// so the card's corner under it squares or rounds in the same pass as the tab's fill. O(1): only
    /// the selected tab is read, so a selection change costs the same at any tab count.
    func reportCornerLead() {
        let on = CornerFlush.current.isOn
        var leads = false
        if on, tabsClip.frame.minX <= 0.5, let id = model.selectedID, let cell = cells[id], let place = placed[id] {
            let frame = cellFrame(place, isPinned: cell.item.isPinned)
            leads = frame.minX <= 0.5 && frame.maxX > 0.5
        }
        if let id = model.selectedID { cells[id]?.cornerFeetSkipsLeading = leads }
        // While it leads, every layout reports too: the strip may have reached the card's corner since.
        guard leads != leadsWithSelection || leads || (on && !reportedCornerFlush) else { return }
        leadsWithSelection = leads
        // Not yet in a window root's tree: report again on the next layout.
        reportedCornerFlush = CornerFlushChrome.stripDidChange(self) && on
    }
}
