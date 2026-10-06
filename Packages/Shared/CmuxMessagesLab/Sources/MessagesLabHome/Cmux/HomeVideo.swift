import AVFoundation
import CmuxHomeCore
import CmuxHomeRender
import QuartzCore

/// Inline video in MessagesLab's video bubbles (Lawrence 2026-10-05,
/// iMessage-like): lane 16's `VideoPlayback` owns the players (URL fetched
/// only on play, refetch of an expired signed GET, the end returns to the
/// start paused); this places each player in its bubble's row cell, under
/// the bubble's mask, and shows MessagesLab's play disc (RowDrawing's
/// measurements: a 32 pt translucent dark disc with a light triangle) while
/// it is paused. MessagesLab's bitmap still draws the poster and the disc at
/// rest. A row that leaves the viewport releases its player and keeps the
/// position.
@MainActor
final class HomeVideo {
    let playback = VideoPlayback()
    weak var controller: ChatController?
    private var badges: [String: CALayer] = [:]
    private var masks: [String: CAShapeLayer] = [:]

    init() {
        playback.onChange = { [weak self] _ in self?.place() }
    }

    static func key(_ ref: PartRef) -> String { "\(ref.messageId):\(ref.partIndex)" }

    func state(_ ref: PartRef) -> HomeVideoState { playback.state(Self.key(ref)) }

    /// Poster or paused: play. Playing: pause. Loading: cancel.
    func toggle(_ ref: PartRef, attachment: AttachmentRef, source: any HomeVideoSource) {
        playback.toggle(Self.key(ref), ref: attachment, media: source)
        place()
    }

    func badgeVisible(_ ref: PartRef) -> Bool {
        guard let badge = badges[Self.key(ref)] else { return false }
        return badge.superlayer != nil && !badge.isHidden
    }

    /// Puts every player in its visible bubble; a row off screen releases it.
    func place() {
        guard let demo = controller?.demo else { return }
        var cells: [String: RowCell] = [:]
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            if let spec = cell.spec, case let .part(p) = spec.kind { cells[Self.key(p.ref)] = cell }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for key in Set(playback.activeKeys).union(badges.keys) {
            guard let layer = playback.layer(key) else {
                badges[key]?.removeFromSuperlayer()
                continue
            }
            guard let cell = cells[key], let spec = cell.spec, case let .part(p) = spec.kind else {
                playback.rowLeft(key)
                layer.removeFromSuperlayer()
                badges[key]?.removeFromSuperlayer()
                continue
            }
            let body = RowDraw.bodyRect(spec)
            if layer.superlayer !== cell.layer { cell.layer.addSublayer(layer) }
            layer.frame = body
            let mask = masks[key] ?? CAShapeLayer()
            masks[key] = mask
            mask.path = BubblePath.cached(size: body.size, outgoing: p.outgoing, tail: p.tail)
            mask.frame = CGRect(origin: .zero, size: body.size)
            layer.mask = mask
            let badge = badges[key] ?? Self.makeBadge()
            badges[key] = badge
            if badge.superlayer !== cell.layer { cell.layer.addSublayer(badge) }
            badge.position = CGPoint(x: body.midX, y: body.midY)
            let state = playback.state(key)
            badge.isHidden = state == .playing
            badge.opacity = state == .loading ? 0.5 : 1
        }
    }

    /// RowDrawing's video disc: black at 50% under a white triangle at 85%.
    private static func makeBadge() -> CALayer {
        let badge = CALayer()
        badge.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        let disc = CAShapeLayer()
        disc.frame = badge.bounds
        disc.path = CGPath(ellipseIn: badge.bounds, transform: nil)
        disc.fillColor = CGColor(gray: 0, alpha: 0.5)
        let tri = CAShapeLayer()
        tri.frame = badge.bounds
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 16 - 5, y: 16 - 8))
        path.addLine(to: CGPoint(x: 16 + 9, y: 16))
        path.addLine(to: CGPoint(x: 16 - 5, y: 16 + 8))
        path.closeSubpath()
        tri.path = path
        tri.fillColor = CGColor(gray: 1, alpha: 0.85)
        badge.addSublayer(disc)
        badge.addSublayer(tri)
        badge.contentsScale = DisplayScale.current
        return badge
    }
}

extension HomeMedia: HomeVideoSource {
    func originalURL(for ref: AttachmentRef) async throws -> URL { try await original(ref) }
}
