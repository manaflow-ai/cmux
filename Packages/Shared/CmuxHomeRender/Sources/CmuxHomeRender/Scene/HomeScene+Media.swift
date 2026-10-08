import CoreGraphics
import QuartzCore

/// Media rows: the picture lands on its row when its bytes arrive (no
/// layout pass, the row was sized from the pixel size), and a playing video
/// sits inside its bubble.
extension HomeScene {
    func wireMedia() {
        media.onImage = { [weak self] hash in self?.mediaArrived(hash) }
        media.onReload = { [weak self] in self?.refreshVisibleRows() }
        video.onChange = { [weak self] key in
            guard let self, let row = self.visible[key], let i = self.visibleIndex[ObjectIdentifier(row)], i < self.model.count
            else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.decorateMedia(row, self.model.rows[i].spec)
            CATransaction.commit()
        }
    }

    /// Puts the cached picture (or starts its load), the player and the play
    /// badge on a media row.
    func decorateMedia(_ row: RowLayer, _ spec: RowSpec) {
        decorateProgress(row, spec)
        guard let p = spec.partRow, let part = p.media else { return }
        let maxPixel = Int((max(p.size.width, p.size.height) * bitmaps.scale).rounded(.up))
        if let image = media.image(for: part, maxPixel: maxPixel) { row.showMedia(image) }
        guard part.isVideo else {
            row.showPlayBadge(false)
            row.setPlayer(nil)
            return
        }
        row.setPlayer(video.layer(spec.key))
        row.showPlayBadge(video.state(spec.key) != .playing)
        row.playBadge.opacity = video.state(spec.key) == .loading ? 0.5 : 1
    }

    /// The upload ring: centred on a media bubble, around a file chip's icon.
    func decorateProgress(_ row: RowLayer, _ spec: RowSpec) {
        guard let p = spec.partRow else { row.showProgress(nil, center: .zero, diameter: 0); return }
        let body = RowArt.bodyRect(spec, metrics: metrics)
        switch p.content {
        case .media(let media):
            row.showProgress(uploadProgress[media.ref.hash], center: CGPoint(x: body.midX, y: body.midY),
                             diameter: min(44, min(body.width, body.height) - 8))
        case .file(let file):
            let icon = FileChip.icon.offsetBy(dx: body.minX, dy: body.minY)
            row.showProgress(uploadProgress[file.hash], center: CGPoint(x: icon.midX, y: icon.midY), diameter: 40)
        case .text:
            row.showProgress(nil, center: .zero, diameter: 0)
        }
    }

    /// New upload progress: only the rows that show an attachment change.
    func setUploadProgress(_ progress: [String: Double]) {
        guard progress != uploadProgress else { return }
        uploadProgress = progress
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, row) in visible {
            if let i = visibleIndex[ObjectIdentifier(row)], i < model.count { decorateProgress(row, model.rows[i].spec) }
        }
        CATransaction.commit()
    }

    private func mediaArrived(_ hash: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, row) in visible where row.mediaHash == hash {
            if let i = visibleIndex[ObjectIdentifier(row)], i < model.count { decorateMedia(row, model.rows[i].spec) }
        }
        CATransaction.commit()
    }
}
