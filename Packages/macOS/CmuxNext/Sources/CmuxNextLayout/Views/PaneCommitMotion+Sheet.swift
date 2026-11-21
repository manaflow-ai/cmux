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
///
/// Where the ground is. In a chrome style with a card for each pane the window shows a shade in the gaps between the
/// panes, and that shade leaves out each pane's card. A pane's clip is its card there (`PaneHostView.wholeCard`), with
/// the card's corners. So the ground is the clip's lowest layer: it covers the card and nothing of the gaps. A colour
/// of the clip's own (the user's colour for the docks) shows over it, as 1 layer of the ground. In each other style
/// the window's sheet is under the pane's whole cell, and the ground is on the cell: on the layer of the pane's host.
///
/// Limits. A plain colour is read at the pass of each act, not at each frame: a change of the window's colour, or of
/// the clip's own colour, shows in a move at the next act or at the motion's end. With a card for each pane, a pane
/// that a move keeps under the others shows in the gaps between the cards over it, under the shade, as with no
/// motion's ground; and a pane that gets smaller has no ground in the room that it gives up, outside its card.
extension PaneCommitMotion {
    /// The name of the layer that shows the window's picture under a pane that moves.
    static let pictureName = "pane.commit.picture"
    /// The name of the layer that is a plain ground inside a pane's card.
    static let cardName = "pane.commit.card"

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

    /// What is under `host` at rest on `screen`, whose window shows `sheet` under its panes: the plain colour of
    /// what holds the pane, or with no holder the window's sheet. Nil: nothing that a pane can show.
    static func ground(under host: PaneHostView, on screen: ScreenContentView, sheet: Sheet?) -> Sheet? {
        let holder = Self.holder(of: host, on: screen)
        return holder.holds ? holder.color.map { .color($0) } : sheet
    }

    /// Each pane of `changes` shows its ground under its content from this pass to the motion's end
    /// (``hideSheets()``). A pane that an act before gave a ground keeps one, also when a later act takes that pane
    /// out: it then stays over the panes that it went over. Each pass reads each pane's ground again, so a pane has
    /// what is under it at the last act, and a pane with no ground now gets its own colour back. A pane that moved
    /// in this motion before with no copy of the picture gets none in a later act: a copy is at its place only with
    /// each move of its pane from the start.
    func showSheet(under changes: [Change], on screen: ScreenContentView) {
        let sheet = Self.sheet(under: screen)
        for change in changes where change.host.layer != nil && !sheets.contains(where: { $0.host === change.host }) {
            sheets.append((host: change.host, color: change.host.layer?.backgroundColor, picture: nil, plain: nil))
        }
        var shown: [(host: PaneHostView, color: CGColor?, picture: CALayer?, plain: CALayer?)] = []
        for var entry in sheets {
            guard let layer = entry.host.layer else { continue }
            // Where the pane's clip is its card, the ground is in the clip: the gaps beside the card keep their shade.
            let card = entry.host.wholeCard ? entry.host.clipView.layer : nil
            var color: CGColor?, still: WindowStillPicture?
            switch Self.ground(under: entry.host, on: screen, sheet: sheet) {
            case .color(let read)?: color = read
            case .picture(let read)?: still = read
            case nil: break
            }
            let onCell = card == nil ? color ?? entry.color : entry.color
            if layer.backgroundColor != onCell { layer.backgroundColor = onCell }
            if let card, let color {
                let plain = entry.plain ?? Self.addPlain(to: card, size: screen.bounds.size)
                if plain.backgroundColor != color { plain.backgroundColor = color }
                entry.plain = plain
            } else if let plain = entry.plain {
                plain.removeFromSuperlayer()
                entry.plain = nil
            }
            if let still {
                if entry.picture == nil, !moved.contains(where: { $0.layer === layer }) {
                    entry.picture = Self.addCopy(of: still, to: card ?? layer, own: card?.backgroundColor)
                }
            } else if let copy = entry.picture {
                copy.removeFromSuperlayer()
                entry.picture = nil
            }
            if color != nil || entry.picture != nil { shown.append(entry) }
        }
        sheets = shown
        // The picture is kept only with a pane that shows it: the motion's end then takes both away.
        if sheets.contains(where: { $0.picture != nil }), case .picture(let still)? = sheet {
            shownPicture = still
            pictured = screen
        } else {
            shownPicture = nil
            pictured = nil
        }
        placePictures()
    }

    /// A copy of the window's picture as the lowest layer of `layer` (a pane host's, or a pane's clip's that is its
    /// card), with the window's tint over it: the picture's own image, fitted as the window fits it. It has no clip
    /// and no transform of its own. `own`: the clip's own colour, over the tint.
    static func addCopy(of picture: WindowStillPicture, to layer: CALayer, own: CGColor? = nil) -> CALayer {
        let copy = CALayer()
        copy.name = pictureName
        copy.contents = picture.contents
        copy.contentsGravity = picture.gravity
        copy.contentsScale = picture.scale
        copy.zPosition = -1
        cover(copy, with: picture.tint)
        cover(copy, with: own)
        layer.insertSublayer(copy, at: 0)
        return copy
    }

    /// A plain ground as the lowest layer of `card`, the layer of a pane's clip that is its card. The clip cuts it
    /// to the card with the card's corners, so it has the size of the screen: it covers the clip at each size that
    /// the clip has in the move. The clip's own colour is over it.
    static func addPlain(to card: CALayer, size: CGSize) -> CALayer {
        let plain = CALayer()
        plain.name = cardName
        plain.zPosition = -1
        plain.frame = CGRect(origin: card.bounds.origin, size: size)
        cover(plain, with: card.backgroundColor)
        card.insertSublayer(plain, at: 0)
        return plain
    }

    /// One layer of `color` over all of `ground`, as its top layer. Nil: none.
    static func cover(_ ground: CALayer, with color: CGColor?) {
        guard let color else { return }
        let over = CALayer()
        over.backgroundColor = color
        over.frame = ground.bounds
        ground.addSublayer(over)
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
            let inCard: Bool = copy.superlayer != nil && copy.superlayer === entry.host.clipView.layer
            let frame = (inCard ? entry.host.clipView : entry.host).convert(picture.frame, from: nil)
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

    /// Each copy of the window's picture and each plain ground in a card goes, and each pane host's layer gets back
    /// the colour that it had before the motion.
    func hideSheets() {
        for entry in sheets {
            entry.picture?.removeFromSuperlayer()
            entry.plain?.removeFromSuperlayer()
            entry.host.layer?.backgroundColor = entry.color
        }
        sheets = []
        shownPicture = nil
        pictured = nil
    }
}
