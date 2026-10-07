import CoreGraphics
import QuartzCore

/// Transactions: each change commits final model values plus additive
/// springs (or, under Reduce Motion, one short cross-fade).
extension HomeScene {
    /// Applies new rows (nil: the rows did not change, only the field moved).
    /// `sendField` is the field rect the send morph flies from; `sendOrigins`
    /// the draft thumbnails attachments fly from, by part index. `animated:
    /// false` commits with no motion (the host animates the change). Returns
    /// how far the rows moved in the viewport (old minus new, design points).
    @discardableResult
    func commit(_ rows: [RowSpec]?, change: TranscriptChange, sendField: CGRect? = nil, sendOrigins: [Int: CGRect] = [:],
                animated: Bool = true) -> CGFloat {
        commitCount += 1
        let begin = now
        let animate = animated && motion.moves && change.animates
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if motion.crossFades, change.animates, rows != nil { beginCrossFade(begin: begin) }
        let oldSnap = model.snapshot
        let oldRowsTop = layout.rowsTop
        let oldOffset = offset
        let anchorKey = pinned ? nil : firstVisibleKey
        let anchorOldTop = anchorKey.flatMap { oldSnap.contentTop($0) }.map { $0 + oldRowsTop }

        if let rows { model.set(rows, at: begin, ghosts: animate) }
        layout.bottomPad = size.height - anchorY
        let rebase = layout.rebaseIfNeeded()
        var newOffset: CGFloat
        if pinned {
            newOffset = pinnedOffset
        } else if let key = anchorKey, let oldTop = anchorOldTop, let i = model.index[key] {
            newOffset = oldOffset + rebase + (layout.contentTop(i) - (oldTop + rebase))
        } else {
            newOffset = oldOffset + rebase
        }
        newOffset = clamped(newOffset)
        setOffset(newOffset)
        if rows != nil { markAllDirty() }
        layoutRows()

        let element = motion(change.element)
        if animate {
            animateRows(change, element, begin: begin, oldSnap: oldSnap, oldRowsTop: oldRowsTop, oldOffset: oldOffset, newOffset: newOffset)
        }
        if case .send(let key) = change, animate, let field = sendField { startMorph(key.rawValue, from: field, origins: sendOrigins, begin: begin) }
        refreshVisibleRows()
        CATransaction.commit()
        scheduleSettle()
        return (oldRowsTop - oldOffset) - (layout.rowsTop - newOffset)
    }

    /// Viewport delta of every row near the viewport as additive springs (one
    /// ledger entry per moved row), plus the fades of rows that appear,
    /// disappear or change.
    private func animateRows(_ change: TranscriptChange, _ element: SpringElement, begin: CFTimeInterval,
                             oldSnap: TranscriptModel.Snapshot, oldRowsTop: CGFloat, oldOffset: CGFloat, newOffset: CGFloat) {
        let band = model.range(newOffset - layout.rowsTop - 600, newOffset - layout.rowsTop + size.height + 600)
        var deltas: [String: CGFloat] = [:]
        var lastDelta: CGFloat?
        var pendingNew: [Int] = []
        for i in band {
            let row = model.rows[i]
            let key = row.spec.key
            let newWin = layout.contentTop(i) - newOffset
            if let oldTop = oldSnap.contentTop(key), let oi = oldSnap.index[key], oldSnap.rows[oi].ghost == row.ghost || row.ghost {
                let d = (oldTop + oldRowsTop - oldOffset) - newWin
                deltas[key] = d
                for j in pendingNew { deltas[model.rows[j].spec.key] = d }
                pendingNew = []
                lastDelta = d
            } else if let last = lastDelta {
                deltas[key] = last
            } else {
                pendingNew.append(i)
            }
        }
        for (key, d) in deltas where abs(d) > 0.01 {
            ledger.add(key, .cell, "position.y", from: Double(d), to: 0, element, begin: begin)
            morphs[key]?.shift(by: Double(d), element, begin: begin)
        }
        for i in band {
            let row = model.rows[i]
            let key = row.spec.key
            if row.ghost, row.removedAt == begin {
                let fade = key == "typing" ? HomeMotion.typingOut : HomeMotion.rowFade
                ledger.add(key, .content, "opacity", from: 1, to: 0, motion(fade), begin: begin)
                continue
            }
            guard row.insertedAt == begin, oldSnap.index[key] == nil else {
                if case .receipt(let new) = row.spec.kind, let oi = oldSnap.index[key],
                   case .receipt(let old) = oldSnap.rows[oi].spec.kind, old != new {
                    receiptChanges[key] = oldSnap.rows[oi].spec
                    ledger.add(key, .receiptOld, "opacity", from: 1, to: 0, motion(HomeMotion.receiptOldOut), begin: begin)
                    ledger.add(key, .receiptNew, "opacity", from: 0, to: 1, motion(HomeMotion.receiptNewIn), begin: begin)
                }
                continue
            }
            switch row.spec.kind {
            case .typing:
                let pop = motion(HomeMotion.typingPop)
                ledger.add(key, .typing, "transform.scale", from: 0, to: 1, pop, begin: begin)
                ledger.add(key, .typing, "opacity", from: 0, to: 1, motion(HomeMotion.typingFade), begin: begin)
                typingBegin = begin + (pop.components.first?.delay ?? 0)
                typingInsertedAt = begin
            case .part:
                switch change {
                case .receive:
                    ledger.add(key, .content, "opacity", from: 0, to: 1, motion(HomeMotion.receivedFade), begin: begin)
                case .send(let item) where key.hasPrefix("part:\(item.rawValue):"):
                    break // hidden while the morph flies (startMorph)
                default:
                    ledger.add(key, .content, "opacity", from: 0, to: 1, motion(HomeMotion.rowFade), begin: begin)
                }
            default:
                ledger.add(key, .content, "opacity", from: 0, to: 1, motion(HomeMotion.receiptIn), begin: begin)
            }
        }
    }

    // MARK: Send morph

    /// Every part of the sent item flies: text from the field, an
    /// attachment from its draft thumbnail when the host gave one.
    private func startMorph(_ item: String, from field: CGRect, origins: [Int: CGRect], begin: CFTimeInterval) {
        let prefix = "part:\(item):"
        for i in model.rows.indices where model.rows[i].spec.key.hasPrefix(prefix) && !model.rows[i].ghost {
            guard let p = model.rows[i].spec.partRow else { continue }
            let key = model.rows[i].spec.key
            let partIndex = Int(key.dropFirst(prefix.count)) ?? 0
            let body = RowArt.bodyRect(model.rows[i].spec, metrics: metrics)
            let top = windowY(contentY: layout.contentTop(i))
            let target = CGRect(x: body.minX, y: top, width: body.width, height: p.size.height)
            let start = p.text == nil ? origins[partIndex] ?? field : field
            let morph = MorphBubble(key: key, in: morphLayer, viewport: root.bounds, from: start, to: target, face: morphFace(p),
                                    palette: palette, motion: motion, begin: begin)
            morphs[key]?.remove()
            morphs[key] = morph
            ledger.add(key, .content, "opacity", from: 0, to: 0, HomeMotion.rowFade, begin: begin, hold: 0, until: morph.landTime)
            if let r = visible[key], let idx = visibleIndex[ObjectIdentifier(r)] { decorate(r, idx) }
        }
    }

    /// The sharp content the morph shows, drawn at the bubble's final size.
    private func morphFace(_ p: PartRow) -> MorphBubble.Face {
        let size = p.size
        let rect = CGRect(origin: .zero, size: size)
        let palette = self.palette
        switch p.content {
        case .text(let text):
            let image = Canvas.image(size: size) { PartDrawing.drawText($0, text, in: rect, outgoing: true, palette: palette) }
            return MorphBubble.Face(image: image, fill: nil, tail: p.tail, scalesWithBody: false)
        case .file(let file):
            let image = Canvas.image(size: size) { AttachmentDrawing.drawChip($0, file, in: rect, outgoing: true, palette: palette) }
            return MorphBubble.Face(image: image, fill: nil, tail: p.tail, scalesWithBody: false)
        case .media(let part):
            let maxPixel = Int((max(size.width, size.height) * bitmaps.scale).rounded(.up))
            let picture = media.image(for: part, maxPixel: maxPixel)
            let image = picture.flatMap { picture in
                Canvas.image(size: size) { ctx in
                    let w = CGFloat(picture.width), h = CGFloat(picture.height)
                    let s = max(size.width / max(1, w), size.height / max(1, h))
                    let fill = CGRect(x: (size.width - w * s) / 2, y: (size.height - h * s) / 2, width: w * s, height: h * s)
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: size.height)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(picture, in: CGRect(x: fill.minX, y: size.height - fill.maxY, width: fill.width, height: fill.height))
                    ctx.restoreGState()
                }
            }
            return MorphBubble.Face(image: image, fill: palette.incomingBubble.cgColor, tail: false, scalesWithBody: true)
        }
    }

    // MARK: Reduce Motion

    /// The old frame as a still that fades out over the new one (no movement).
    private func beginCrossFade(begin: CFTimeInterval) {
        crossFade?.removeFromSuperlayer()
        let still = CALayer()
        still.actions = RowLayer.noActions
        still.contentsScale = Canvas.scale
        still.frame = clip.frame
        still.contents = Canvas.snapshot(root, rect: CGRect(origin: .zero, size: size), background: palette.background.cgColor)
        still.opacity = Animate.hiddenOpacity
        root.addSublayer(still)
        let duration = motion.time(HomeMotion.crossFade)
        Animate.fadeOut(still, begin: begin, duration: duration)
        crossFade = still
        crossFadeEnd = begin + duration
    }

    // MARK: Cleanup

    /// The next layer time something needs cleanup (nil: nothing pending).
    var nextSettle: CFTimeInterval? {
        var due: [CFTimeInterval] = []
        if let end = ledger.lastEnd { due.append(end) }
        due += morphs.values.map(\.landTime)
        if crossFade != nil { due.append(crossFadeEnd) }
        due += model.rows.compactMap(\.removedAt).map { $0 + HomeMotion.ghostLifetime }
        return due.min()
    }

    func scheduleSettle() {
        if let due = nextSettle { requestWake(due) }
    }

    /// Cleanup at layer time `t`: finished ledger entries, landed morphs,
    /// faded ghosts, the cross-fade. Event-driven (one wake per due time).
    func settle(at t: CFTimeInterval) {
        ledger.prune(before: t)
        receiptChanges = receiptChanges.filter { key, _ in ledger.live(key).contains { $0.target == .receiptOld } }
        for (key, m) in morphs where m.landTime <= t {
            m.remove()
            morphs[key] = nil
        }
        if let cf = crossFade, crossFadeEnd <= t {
            cf.removeFromSuperlayer()
            crossFade = nil
        }
        if model.dropGhosts(before: t - HomeMotion.ghostLifetime) {
            let anchor = visibleAnchor()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            markAllDirty()
            restore(anchor)
            CATransaction.commit()
        }
        scheduleSettle()
    }
}
