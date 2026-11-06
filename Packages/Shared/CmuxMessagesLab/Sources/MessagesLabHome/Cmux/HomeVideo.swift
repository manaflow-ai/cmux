import AppKit
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
    /// cmux: the expand button at a played video's top right (opens the large viewer).
    private var expands: [String: CALayer] = [:]
    /// cmux: the open large viewer (one per pane).
    private(set) weak var viewer: HomeVideoViewer?

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

    /// cmux: the expand button's frame in a video bubble of `body` (row coordinates): 26 pt at
    /// the top right, 7 pt in. It shows once the video played (the poster shows the play disc).
    nonisolated static func expandRect(body: CGRect) -> CGRect {
        CGRect(x: body.maxX - 7 - 26, y: body.minY + 7, width: 26, height: 26)
    }

    /// cmux: opens the video in the large viewer over `host` (a double-click, the expand button,
    /// View Larger). A playing bubble pauses; the viewer starts where it was, and on close the
    /// bubble stays paused at its frame.
    func openLarge(_ ref: PartRef, attachment: AttachmentRef, source: any HomeVideoSource, in host: NSView) {
        let key = Self.key(ref)
        let start = playback.currentTime(key)
        playback.pause(key)
        viewer?.close()
        let size = attachment.width.flatMap { w in attachment.height.map { CGSize(width: w, height: $0) } }
        let v = HomeVideoViewer(frame: host.bounds, videoSize: size)
        v.onClose = { [weak self, weak host] _ in
            self?.place()
            if let controller = self?.controller { controller.focusCompose() } else { host?.window?.makeFirstResponder(host) }
        }
        host.addSubview(v, positioned: .above, relativeTo: nil)
        host.window?.makeFirstResponder(v)
        viewer = v
        // task-owner: one fetch; the viewer plays it if it is still open.
        Task { [weak v, weak source] in
            guard let source, let url = try? await source.originalURL(for: attachment), let v, v.superview != nil else { return }
            v.play(url, from: start)
        }
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
            if let spec = cell.spec, case let .part(p) = spec.kind { cells.updateValue(cell, forKey: Self.key(p.ref)) } // crash program: dictionary write
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for key in Set(playback.activeKeys).union(badges.keys) {
            guard let layer = playback.layer(key) else {
                badges[key]?.removeFromSuperlayer()
                expands[key]?.removeFromSuperlayer()
                continue
            }
            guard let cell = cells[key], let spec = cell.spec, case let .part(p) = spec.kind else {
                playback.rowLeft(key)
                layer.removeFromSuperlayer()
                badges[key]?.removeFromSuperlayer()
                expands[key]?.removeFromSuperlayer()
                continue
            }
            // On the row's content, which RowCell.snapRow moves onto the window's device pixels (MessagesLab c1457e5).
            let body = RowDraw.bodyRect(spec).offsetBy(dx: cell.rowSnap.x, dy: cell.rowSnap.y)
            if layer.superlayer !== cell.layer { cell.layer.addSublayer(layer) }
            layer.frame = body
            let mask = masks[key] ?? CAShapeLayer()
            masks[key] = mask
            mask.path = BubblePath.balloon(frame: CGRect(origin: .zero, size: body.size), row: p).cgPath  // cmux: the shared bubble outline
            mask.frame = CGRect(origin: .zero, size: body.size)
            layer.mask = mask
            let badge = badges[key] ?? Self.makeBadge()
            badges.updateValue(badge, forKey: key) // // crash program: dictionary write
            if badge.superlayer !== cell.layer { cell.layer.addSublayer(badge) }
            // This pane's own scale (MessagesLab 258b385: two panes can be at two scales).
            let scale = demo.renderScale
            for l in [badge, mask] + (badge.sublayers ?? []) where l.contentsScale != scale { l.contentsScale = scale }
            badge.position = CGPoint(x: body.midX, y: body.midY)
            let state = playback.state(key)
            badge.isHidden = state == .playing
            badge.opacity = state == .loading ? 0.5 : 1
            let expand = expands[key] ?? Self.makeExpand()
            expands.updateValue(expand, forKey: key) // crash program: dictionary write
            if expand.superlayer !== cell.layer { cell.layer.addSublayer(expand) }
            for l in [expand] + (expand.sublayers ?? []) where l.contentsScale != scale { l.contentsScale = scale }
            expand.frame = Self.expandRect(body: body)
        }
    }

    /// cmux: the expand button: a dark rounded square under two white corner arrows.
    private static func makeExpand() -> CALayer {
        let box = CALayer()
        box.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
        box.cornerRadius = 7
        box.backgroundColor = CGColor(gray: 0, alpha: 0.55)
        let arrows = CAShapeLayer()
        arrows.frame = box.bounds
        let path = CGMutablePath()
        // Top right corner and bottom left corner, each an L with a diagonal to the centre.
        path.move(to: CGPoint(x: 15, y: 7)); path.addLine(to: CGPoint(x: 19, y: 7)); path.addLine(to: CGPoint(x: 19, y: 11))
        path.move(to: CGPoint(x: 19, y: 7)); path.addLine(to: CGPoint(x: 14.5, y: 11.5))
        path.move(to: CGPoint(x: 11, y: 19)); path.addLine(to: CGPoint(x: 7, y: 19)); path.addLine(to: CGPoint(x: 7, y: 15))
        path.move(to: CGPoint(x: 7, y: 19)); path.addLine(to: CGPoint(x: 11.5, y: 14.5))
        arrows.path = path
        arrows.strokeColor = CGColor(gray: 1, alpha: 0.92)
        arrows.fillColor = nil
        arrows.lineWidth = 1.6
        arrows.lineCap = .round
        arrows.lineJoin = .round
        box.addSublayer(arrows)
        box.contentsScale = DisplayScale.current
        return box
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
