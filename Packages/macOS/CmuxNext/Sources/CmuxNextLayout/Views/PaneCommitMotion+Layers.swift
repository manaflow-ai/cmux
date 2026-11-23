import AppKit
import CmuxNextDesign

/// What a pane's move puts on layers: the moves themselves, the ground beside a pane that gets smaller, the move of
/// a pane's ring, and where a new divider line starts.
extension PaneCommitMotion {
    /// The name of each ground strip's layer.
    static let groundName = "pane.commit.ground"

    /// Adds a move to `layer`: it shows `origin` away from its place and `size` larger than its size, and goes to
    /// both. The animations add to the layer's values, so a move that is already on the layer goes on under this one.
    func move(_ layer: CALayer, _ token: MotionSpring, origin: CGPoint, size: CGSize) {
        let anchor = layer.anchorPoint
        let point = CGPoint(x: origin.x + anchor.x * size.width, y: origin.y + anchor.y * size.height)
        if point != .zero { add("position", from: NSValue(point: point), to: NSValue(point: .zero), on: layer, token) }
        if size != .zero { add("bounds.size", from: NSValue(size: size), to: NSValue(size: .zero), on: layer, token) }
    }

    /// Adds one animation of this motion to `layer`; ``finish()`` takes it away.
    func add(_ keyPath: String, from: NSValue, to: NSValue, on layer: CALayer, _ token: MotionSpring) {
        let animation = Motion.panes.springAnimation(token, keyPath, from: from, to: to)
        animation.isAdditive = true
        let key = "pane.commit.\(serial).\(keyPath)"
        layer.add(animation, forKey: key)
        moved.append((layer: layer, key: key))
    }

    /// A pane that gets smaller has its content at its new size from the frame that shows the change: until the
    /// pane's edge is there, strips of the pane's own ground fill the room beside and below the content, inside the
    /// pane's moving clip, so no pixel of the window's backdrop and none of another pane shows there. A pane that
    /// comes has none (it has no room at its start), and a content that keeps its own old picture needs none.
    func showGround(beside change: Change) {
        let id = ObjectIdentifier(change.host)
        guard !change.comes, holds[id] == nil, let layer = change.host.layer, let color = change.host.content.paneGroundColor else { return }
        // A second act while the strips show keeps the largest room that the pane showed in this motion.
        let had = grounds[id]?.extent ?? .zero
        let extent = CGSize(width: max(had.width, change.old.width), height: max(had.height, change.old.height))
        let new = change.new.size
        var rects: [CGRect] = []
        if extent.width > new.width {
            rects.append(CGRect(x: new.width, y: 0, width: extent.width - new.width, height: max(extent.height, new.height)))
        }
        if extent.height > new.height {
            rects.append(CGRect(x: 0, y: new.height, width: new.width, height: extent.height - new.height))
        }
        for strip in Self.strips(of: layer) { strip.removeFromSuperlayer() }
        grounds[id] = rects.isEmpty ? nil : (layer: layer, extent: extent)
        for rect in rects {
            let strip = CALayer()
            strip.name = Self.groundName
            strip.backgroundColor = color
            strip.frame = rect
            layer.addSublayer(strip)
        }
    }

    /// The ground strips on a pane host's layer.
    static func strips(of layer: CALayer) -> [CALayer] {
        (layer.sublayers ?? []).filter { $0.name == groundName }
    }

    /// The panes that a close took out stay where they show, with no move, under every other view of their screen:
    /// the panes that take their room grow over them. Their rings hide now. ``finish()`` gives each layer its
    /// `zPosition` back, and hides the panes. A pane that a later change took back into the layout gets it back here:
    /// until then it shows no ring (`PaneHostView.hidesRing`), also in the turn of the key that took it back.
    func keepUnder(_ hosts: [PaneHostView]) {
        under.removeAll { entry in
            guard !entry.host.isLeaving else { return false }
            entry.host.layer?.zPosition = entry.z
            return true
        }
        for host in hosts {
            host.chrome.isHidden = true
            guard let layer = host.layer, !under.contains(where: { $0.host === host }) else { continue }
            under.append((host: host, z: layer.zPosition))
            layer.zPosition = Self.underZ
        }
    }

    /// The `zPosition` of a pane host's layer while a move keeps the pane under the others.
    static let underZ: CGFloat = -1

    /// A pane's ring (its border, focus ring and dim, in the layout's overlay plane) gets the pane's move, and each
    /// of its layers the change of size.
    func moveRing(of change: Change, _ token: MotionSpring) {
        guard let ring = change.host.chrome.layer else { return }
        move(ring, token, origin: change.origin, size: change.size)
        guard change.size != .zero else { return }
        for layer in ring.sublayers ?? [] { move(layer, token, origin: .zero, size: change.size) }
    }

    /// How far a new divider line whose frame is `line` starts from its place: with the edge of the pane of `change`
    /// that the line is on, when that pane comes. Nil: the line is on no moving edge of that pane.
    static func edge(of change: Change, at line: CGRect) -> CGPoint? {
        guard change.comes else { return nil }
        let old = change.old, new = change.new
        let reach = max(4, min(line.width, line.height))
        if old.width == 0, line.height >= line.width, line.minY < new.maxY, line.maxY > new.minY {
            // The pane opens to the left from its right edge, or to the right from its left edge.
            if old.minX > new.minX, abs(line.midX - new.minX) <= reach { return CGPoint(x: new.width, y: 0) }
            if old.minX == new.minX, abs(line.midX - new.maxX) <= reach { return CGPoint(x: -new.width, y: 0) }
        }
        if old.height == 0, line.width >= line.height, line.minX < new.maxX, line.maxX > new.minX {
            if old.minY > new.minY, abs(line.midY - new.minY) <= reach { return CGPoint(x: 0, y: new.height) }
            if old.minY == new.minY, abs(line.midY - new.maxY) <= reach { return CGPoint(x: 0, y: -new.height) }
        }
        return nil
    }
}

extension PaneHostView {
    /// Whether this pane's ring is hidden: the host is hidden, or a move keeps it shown under the other panes
    /// (``PaneCommitMotion/keepUnder(_:)``). A pane that a second key takes back into the layout while a zoom's pane
    /// still moves over it gets its ring in the pass that shows that key's change, not in the key's turn.
    var hidesRing: Bool { isHidden || layer?.zPosition == PaneCommitMotion.underZ }
}
