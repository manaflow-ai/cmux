import AVFoundation
import CmuxHomeCore
import CmuxHomeRender
import QuartzCore

/// Audio messages play in their bubble (user, 2026-10-21: an iPhone's audio
/// message never reached the Mac as one). A click on the bubble plays or
/// pauses it; one plays at a time, and each keeps its place. While one plays
/// or is paused part way, an overlay on its row draws the played bars in full
/// ink over the bitmap's dim ones and the pause (or play) glyph over the
/// disc; at the end it returns to the start. The bytes come from the store
/// through ``HomeMedia`` (its local copy when it is my send).
@MainActor
final class HomeAudio {
    weak var controller: ChatController?
    /// Where the bytes come from (the projection's media).
    weak var source: HomeMedia?

    private struct Entry {
        var state: HomeVideoState
        var position: CMTime = .zero
    }
    private var entries: [String: Entry] = [:]
    private var current: String?
    private var player: AVPlayer?
    private var load: Task<Void, Never>?
    private var tick: Any?
    private var endObserver: (any NSObjectProtocol)?
    private var overlays: [String: Overlay] = [:]

    static func key(_ ref: PartRef) -> String { "\(ref.messageId):\(ref.partIndex)" }

    func state(_ ref: PartRef) -> HomeVideoState { entries[Self.key(ref)]?.state ?? .poster }

    /// Idle or paused: play (pausing any other). Playing: pause. Loading: cancel.
    func toggle(_ ref: PartRef, attachment: AttachmentRef) {
        let key = Self.key(ref)
        switch state(ref) {
        case .playing:
            player?.pause()
            entries[key]?.position = player?.currentTime() ?? .zero
            entries[key]?.state = .paused
        case .loading:
            load?.cancel()
            load = nil
            entries[key]?.state = .poster
        case .poster, .paused:
            play(key, attachment: attachment)
        }
        place()
    }

    private func play(_ key: String, attachment: AttachmentRef) {
        if let current, current != key { pauseCurrent() }
        var entry = entries[key] ?? Entry(state: .poster)
        if current == key, let player, player.currentItem?.status != .failed {
            player.play()
            entry.state = .playing
            entries[key] = entry
            return
        }
        entry.state = .loading
        entries[key] = entry
        load?.cancel()
        // task-owner: one fetch per play; cancelled by a second click or another bubble's play
        load = Task { [weak self] in
            let url = try? await self?.source?.original(attachment)
            guard let self, !Task.isCancelled else { return }
            self.load = nil
            guard let url else {
                self.entries[key]?.state = .poster
                self.place()
                return
            }
            self.start(key, url: url)
        }
    }

    private func start(_ key: String, url: URL) {
        stopPlayer()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        current = key
        let position = entries[key]?.position ?? .zero
        if position > .zero { player.seek(to: position) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) {
            [weak self] _ in
            // main-proof: addObserver(queue: .main) runs this block on the main queue.
            MainActor.assumeIsolated { self?.ended(key) }
        }
        // 30 updates a second while it plays: the played bars move with the sound.
        tick = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            // main-proof: the observer is delivered on the main queue.
            MainActor.assumeIsolated { self?.placeProgress() }
        }
        entries[key]?.state = .playing
        player.play()
        place()
    }

    private func pauseCurrent() {
        guard let current, let player else { return }
        player.pause()
        entries[current]?.position = player.currentTime()
        if entries[current]?.state == .playing || entries[current]?.state == .loading { entries[current]?.state = .paused }
    }

    private func ended(_ key: String) {
        entries[key] = Entry(state: .poster)
        stopPlayer()
        place()
    }

    private func stopPlayer() {
        if let tick, let player { player.removeTimeObserver(tick) }
        tick = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        current = nil
    }

    /// 0...1 through `key`'s recording.
    private func progress(_ key: String, duration: Double) -> CGFloat {
        let time = key == current ? player?.currentTime() : entries[key]?.position
        guard let time, duration > 0 else { return 0 }
        return CGFloat(max(0, min(1, time.seconds / duration)))
    }

    /// Puts an overlay on each visible bubble that is playing or paused part way.
    func place() {
        guard let demo = controller?.demo else { return }
        var cells: [String: RowCell] = [:]
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            if let spec = cell.spec, case let .part(p) = spec.kind { cells.updateValue(cell, forKey: Self.key(p.ref)) } // crash program: dictionary write
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for key in Set(entries.keys).union(overlays.keys) {
            let entry = entries[key] ?? Entry(state: .poster)
            guard let cell = cells[key], let spec = cell.spec, case let .part(p) = spec.kind,
                  case let .attachment(a) = p.part, a.kind == "voiceMemo",
                  entry.state != .poster || entry.position > .zero else {
                overlays.removeValue(forKey: key)?.layer.removeFromSuperlayer()
                continue
            }
            let overlay = overlays[key] ?? Overlay()
            overlays[key] = overlay
            if overlay.layer.superlayer !== cell.layer { cell.layer.addSublayer(overlay.layer) }
            let body = RowDraw.bodyRect(spec).offsetBy(dx: cell.rowSnap.x, dy: cell.rowSnap.y)
            overlay.update(attachment: a, outgoing: p.outgoing, body: body, playing: entry.state == .playing,
                           loading: entry.state == .loading, progress: progress(key, duration: a.durationSeconds ?? 0),
                           scale: demo.renderScale)
        }
    }

    /// The tick: only the played width changes.
    private func placeProgress() {
        guard let current, let overlay = overlays[current] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.setProgress(progress(current, duration: overlay.duration))
        CATransaction.commit()
    }

    /// One bubble's played bars and glyph, in the row's coordinates.
    private final class Overlay {
        let layer = CALayer()
        private let played = CAShapeLayer()
        private let playedMask = CALayer()
        private let disc = CAShapeLayer()
        private let glyph = CAShapeLayer()
        private var barsFrame = CGRect.zero
        private(set) var duration: Double = 0

        init() {
            let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "fillColor": NSNull(),
                                             "opacity": NSNull(), "frame": NSNull(), "contents": NSNull()]
            for l in [layer, played, playedMask, disc, glyph] { l.actions = still }
            playedMask.backgroundColor = CGColor(gray: 1, alpha: 1)
            played.mask = playedMask
            layer.addSublayer(played)
            layer.addSublayer(disc)
            layer.addSublayer(glyph)
        }

        func update(attachment a: Attachment, outgoing: Bool, body: CGRect, playing: Bool, loading: Bool, progress: CGFloat, scale: CGFloat) {
            duration = a.durationSeconds ?? 0
            for l in [layer, played, playedMask, disc, glyph] where l.contentsScale != scale { l.contentsScale = scale }
            layer.frame = body
            let local = CGRect(origin: .zero, size: body.size)
            let ink = (outgoing ? Fixture.outgoingText : Fixture.incomingText).cgColor
            let bubble = (outgoing ? Fixture.outgoing : Fixture.incoming).cgColor
            let bars = CGMutablePath()
            let rects = VoiceMemoLevels.barRects(VoiceMemoLevels.load(a.asset), body: local)
            for r in rects { bars.addRoundedRect(in: r, cornerWidth: 1, cornerHeight: 1) }
            played.frame = local
            played.path = bars
            played.fillColor = ink
            barsFrame = rects.reduce(CGRect.null) { $0.union($1) }
            setProgress(progress)
            let d = VoiceMemoLevels.discRect(body: local)
            disc.frame = local
            disc.path = CGPath(ellipseIn: d, transform: nil)
            disc.fillColor = ink
            glyph.frame = local
            glyph.fillColor = bubble
            glyph.opacity = loading ? 0.5 : 1
            let g = CGMutablePath()
            if playing {
                g.addRect(CGRect(x: d.midX - 4.5, y: d.midY - 5, width: 3, height: 10))
                g.addRect(CGRect(x: d.midX + 1.5, y: d.midY - 5, width: 3, height: 10))
            } else {
                // RowDrawing's play triangle.
                g.move(to: CGPoint(x: d.minX + 8.5, y: d.midY - 5.5))
                g.addLine(to: CGPoint(x: d.minX + 16.5, y: d.midY))
                g.addLine(to: CGPoint(x: d.minX + 8.5, y: d.midY + 5.5))
                g.closeSubpath()
            }
            glyph.path = g
        }

        func setProgress(_ progress: CGFloat) {
            guard !barsFrame.isNull else { return }
            playedMask.frame = CGRect(x: 0, y: 0, width: barsFrame.minX + barsFrame.width * progress, height: layer.bounds.height)
        }
    }
}
