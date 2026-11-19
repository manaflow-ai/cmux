import AppKit
import CmuxNextDesign

/// The ground under a pane that moves.
///
/// A pane's tab row has no ground of its own, and neither has the padding around its content: at rest what is under
/// the pane shows there. A pane that a move keeps under the others (a pane that a close took out, a pane that a zoom
/// covers, the panes that an unzoom's pane closes over) would show there too, under the pane that goes over it. So
/// a pane that moves has under its own content, on its whole cell, what is under it at rest: it shows what it shows
/// at rest, and nothing of a pane under it.
///
/// What is under a pane at rest, by what holds the pane (``holder(of:on:)``):
/// - A strip pane, and a pane of a column at the screen's edge in the `docked` mode: the window's sheet. That mode
///   has no view under its panes; a colour that the user set for the docks is on the pane's own clip, over this
///   ground.
///   - An opaque window's sheet is one plain colour: the pane has that colour on its host's layer. No layer more,
///     no mask, and no pass of its own in a frame.
///   - A window with a picture background shows one still picture with one tint over it
///     (`WindowMaterialView.stillPicture`): the pane has a copy of the picture's layer as its host's lowest layer,
///     the same image at the same size, with the tint over it. The host's layer clips the copy to the pane's cell.
///     The copy is at the place in the pane where the window has the picture.
///   - Another window (Liquid Glass, a blurred or see-through picture, a video, a living wallpaper, a picture or a
///     tint in a change) has no ground that a pane can show: the pane gets none.
/// - A pane of a column in the `overlay` mode: the opaque ground of the column's backdrop, a colour, in each window.
/// - A floating pane: its card's colour when the card is one opaque colour; with a see-through look or a tint, none.
extension PaneCommitMotion {
    /// The name of the layer that shows the window's picture under a pane that moves.
    static let pictureName = "pane.commit.picture"

    /// What a window shows under its panes, when a pane can show the same under its own content.
    enum Sheet {
        /// One plain colour: an opaque window's own background colour, with no alpha.
        case color(CGColor)
        /// One still picture with its tint: what the window's backdrop reads as.
        case picture(WindowStillPicture)
    }

    /// What the window of `screen` shows under its panes. Nil: nothing that a pane can show (no window, a colour
    /// with alpha, a backdrop that is no still picture).
    static func sheet(under screen: ScreenContentView) -> Sheet? {
        guard let window = screen.window else { return nil }
        guard window.isOpaque else {
            guard case .still(let picture)? = WindowMaterialView.backdrop(of: window)?.stillPicture else { return nil }
            return .picture(picture)
        }
        var read: CGColor?
        screen.effectiveAppearance.performAsCurrentDrawingAppearance { read = window.backgroundColor?.cgColor }
        guard let color = read, color.alpha >= 1 else { return nil }
        return .color(color)
    }

    /// What holds `host` on `screen` over the window's sheet, and the plain colour that it shows under the pane: the
    /// card of a floating pane (nil with a see-through look or a tint), or the opaque ground of the backdrop of a
    /// column in the `overlay` mode. `holds` false: the window's sheet is under the pane (a strip pane, a pane of a
    /// column in the `docked` mode).
    static func holder(of host: PaneHostView, on screen: ScreenContentView) -> (holds: Bool, color: CGColor?) {
        let geometry = screen.baseGeometry
        if geometry.floatingCards[host.pane] != nil { return (true, screen.floatState.cards[host.pane]?.solidGround) }
        if let dock = geometry.dockFrame(containing: host.pane), dock.dock.mode == .overlay,
           let fill = screen.backdrops[dock.column]?.ground, fill.alpha >= 1 {
            return (true, fill)
        }
        return (false, nil)
    }

    /// The colour of what is under `host` at rest on `screen`, whose window's sheet is the colour `sheet`. Nil: no
    /// plain colour.
    static func ground(under host: PaneHostView, on screen: ScreenContentView, sheet: CGColor?) -> CGColor? {
        let holder = Self.holder(of: host, on: screen)
        return holder.holds ? holder.color : sheet
    }

    /// Each pane of `changes` shows its ground under its content from this pass to the motion's end
    /// (``hideSheets()``). A pane that an act before gave a ground keeps one, also when a later act takes that pane
    /// out: it then stays over the panes that it went over. Each pass reads each pane's ground again, so a pane has
    /// what is under it at the last act, and a pane with no ground now gets its own colour back. A pane that moved
    /// in this motion before with no copy of the picture gets none in a later act: a copy is at its place only with
    /// each move of its pane from the start.
    func showSheet(under changes: [Change], on screen: ScreenContentView) {
        var plain: CGColor?, still: WindowStillPicture?
        switch Self.sheet(under: screen) {
        case .color(let color)?: plain = color
        case .picture(let picture)?: still = picture
        case nil: break
        }
        for change in changes where change.host.layer != nil && !sheets.contains(where: { $0.host === change.host }) {
            sheets.append((host: change.host, color: change.host.layer?.backgroundColor, picture: nil))
        }
        var shown: [(host: PaneHostView, color: CGColor?, picture: CALayer?)] = []
        for var entry in sheets {
            guard let layer = entry.host.layer else { continue }
            let holder = Self.holder(of: entry.host, on: screen)
            let ground = holder.holds ? holder.color : plain
            let color = ground ?? entry.color
            if layer.backgroundColor != color { layer.backgroundColor = color }
            if let still, !holder.holds {
                if entry.picture == nil, !moved.contains(where: { $0.layer === layer }) {
                    entry.picture = Self.addCopy(of: still, to: layer)
                }
            } else if let copy = entry.picture {
                copy.removeFromSuperlayer()
                entry.picture = nil
            }
            if ground != nil || entry.picture != nil { shown.append(entry) }
        }
        sheets = shown
        // The picture is kept only with a pane that shows it: the motion's end then takes both away.
        let pictures = sheets.contains { $0.picture != nil }
        shownPicture = pictures ? still : nil
        pictured = pictures ? screen : nil
        placePictures()
    }

    /// A copy of the window's picture as the lowest layer of `layer`, with the window's tint over it: the picture's
    /// own image, fitted as the window fits it. It has no clip and no transform of its own.
    static func addCopy(of picture: WindowStillPicture, to layer: CALayer) -> CALayer {
        let copy = CALayer()
        copy.name = pictureName
        copy.contents = picture.contents
        copy.contentsGravity = picture.gravity
        copy.contentsScale = picture.scale
        copy.zPosition = -1
        if let tint = picture.tint {
            let over = CALayer()
            over.backgroundColor = tint
            copy.addSublayer(over)
        }
        layer.insertSublayer(copy, at: 0)
        return copy
    }

    /// The copy of the window's picture on a pane host's layer.
    static func picture(on layer: CALayer) -> CALayer? {
        (layer.sublayers ?? []).first { $0.name == pictureName }
    }

    /// Puts each copy where the window has the picture, in its pane's own coordinates. Each pass that places the
    /// panes does this, also one with no act (a divider's drag, a scroll): a pane with a new place has its copy
    /// where the picture is.
    func placePictures() {
        guard let picture = shownPicture else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in sheets {
            guard let copy = entry.picture else { continue }
            let frame = entry.host.convert(picture.frame, from: nil)
            copy.bounds = CGRect(origin: .zero, size: frame.size)
            copy.position = CGPoint(x: frame.midX, y: frame.midY)
            for tint in copy.sublayers ?? [] { tint.frame = copy.bounds }
        }
        CATransaction.commit()
    }

    /// Whether the window still shows the picture that the copies show, at the same place, with the same tint. With
    /// no copy: true. A new picture, a new tint, a window with a new size: false, and the motion ends.
    var pictureStays: Bool {
        guard let shown = shownPicture else { return true }
        guard let screen = pictured, case .picture(let now)? = Self.sheet(under: screen) else { return false }
        return now.isSame(as: shown)
    }

    /// Each copy of the window's picture goes, and each pane host's layer gets back the colour that it had before
    /// the motion.
    func hideSheets() {
        for entry in sheets {
            entry.picture?.removeFromSuperlayer()
            entry.host.layer?.backgroundColor = entry.color
        }
        sheets = []
        shownPicture = nil
        pictured = nil
    }
}
