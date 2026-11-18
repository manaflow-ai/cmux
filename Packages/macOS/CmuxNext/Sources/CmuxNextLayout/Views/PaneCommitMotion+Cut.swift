import AppKit
import CmuxNextDesign

/// What a move cuts from the panes that it keeps under the others.
///
/// A pane that a close took out, and a pane that a zoom covers, show under the panes of the layout to the motion's
/// end (``keepUnder(_:)``). A pane's tab strip has no ground of its own, and in a see-through window its content has
/// none. So without a cut a kept pane shows through the pane that goes over it: its tabs in that pane's tabs, its
/// content under them. A kept pane shows only where no pane of the layout shows: a mask on its clip takes out one
/// hole, the box of the panes that move over it. The mask on the host's own layer (`PaneHostView.setStripClip`)
/// stays as it is.
///
/// The mask is 4 bands around the hole, one on each side of it. Each band gets the move of its edge of the hole as a
/// pane's layer gets its move: one animation of `position` that adds to the layer's value, on the act's spring, in
/// the act's own transaction. So an edge of the hole is on the edge of the pane over it in each frame, and a second
/// act in the move adds to a band as it adds to a pane: nothing starts again, and no code runs in a frame.
///
/// - The hole is one box. Two panes that move over one kept pane with a gap between them hide it in the gap too.
/// - The hole never gets smaller in a motion: a pane that goes off a kept pane in a later act leaves it hidden there.
/// - A pane that is kept while it still moves (a second close of the pane that the first close made grow) takes its
///   clip and the mask with it. The mask's layer gets that move the other way, with that move's own start time, so
///   the hole stays on the pane over it.
extension PaneCommitMotion {
    /// The name of the mask on a kept pane's clip.
    static let cutName = "pane.commit.cut"

    /// How far each band goes from the hole: past each edge of a clip, and of a content that is larger than its clip.
    static let cutReach: CGFloat = 100_000

    /// The 4 bands around `hole`, in the mask's coordinates: before it in x, after it in x, before it in y, after it
    /// in y.
    static func bands(around hole: CGRect) -> [CGRect] {
        let far = cutReach, all = 2 * far
        let before = CGRect(x: hole.minX - far, y: -far, width: far, height: all), after = CGRect(x: hole.maxX, y: -far, width: far, height: all)
        let above = CGRect(x: -far, y: hole.minY - far, width: all, height: far), below = CGRect(x: -far, y: hole.maxY, width: all, height: far)
        return [before, after, above, below]
    }

    /// Cuts from each pane that the move keeps under the others the box of the panes of `panes` that are over it at
    /// the start or at the end of their moves, from where the box was to where it is, with `token`. A kept pane that
    /// none of them is over gets no mask, and a mask of an act before stays as it is.
    func cutKept(under panes: [Change], _ token: MotionSpring) {
        for (host, _) in under {
            guard let clip = host.clipView.layer, let screen = host.superview else { continue }
            let place = host.frame
            func isOver(_ rect: CGRect) -> Bool {
                let shared = rect.intersection(place)
                return !shared.isNull && shared.width > 0.5 && shared.height > 0.5
            }
            let over = panes.filter { $0.host !== host && (isOver($0.old) || isOver($0.new)) }
            guard !over.isEmpty else { continue }
            func box(_ rects: [CGRect]) -> CGRect {
                host.clipView.convert(rects.reduce(CGRect.null) { $0.union($1) }, from: screen)
            }
            var start = box(over.map(\.old)), end = box(over.map(\.new))
            let bands: [CALayer]
            if let mask = clip.mask, mask.name == Self.cutName, let had = mask.sublayers, had.count == 4 {
                // The hole of the act before: each pane that was over this one then is in it.
                let x = had[0].frame.maxX, y = had[2].frame.maxY
                start = CGRect(x: x, y: y, width: had[1].frame.minX - x, height: had[3].frame.minY - y)
                end = end.union(start)
                bands = had
            } else {
                bands = cut(clip, of: host)
            }
            let from = Self.bands(around: start), to = Self.bands(around: end)
            for (index, band) in bands.enumerated() {
                band.frame = to[index]
                let offset = CGPoint(x: from[index].minX - to[index].minX, y: from[index].minY - to[index].minY)
                if offset != .zero { add("position", from: NSValue(point: offset), to: NSValue(point: .zero), on: band, token) }
            }
        }
    }

    /// Puts a new mask on `clip`, the clip of `host`, and returns its 4 bands. The mask's coordinates are the clip's.
    /// Each move of an act before that is still on the host's layer moves the clip too: the mask's layer gets it the
    /// other way, with the same spring and the same start, so the mask stays where it is on the screen.
    private func cut(_ clip: CALayer, of host: PaneHostView) -> [CALayer] {
        let far = Self.cutReach
        let mask = CALayer()
        mask.name = Self.cutName
        mask.bounds = CGRect(x: -far, y: -far, width: 2 * far, height: 2 * far)
        mask.position = .zero
        let bands = (0..<4).map { _ in CALayer() }
        for band in bands {
            band.backgroundColor = CGColor(gray: 0, alpha: 1) // colour-allow: alpha-only mask coverage; this colour is never displayed
            mask.addSublayer(band)
        }
        clip.mask = mask
        guard let layer = host.layer else { return bands }
        let anchor = layer.anchorPoint
        for key in layer.animationKeys() ?? [] where key.hasPrefix("pane.commit.") && key.hasSuffix(".position") {
            guard let act = Int(key.dropFirst("pane.commit.".count).dropLast(".position".count)),
                  let position = layer.animation(forKey: key) as? CABasicAnimation, let point = (position.fromValue as? NSValue)?.pointValue,
                  let counter = position.copy() as? CABasicAnimation else { continue }
            let size = ((layer.animation(forKey: "pane.commit.\(act).bounds.size") as? CABasicAnimation)?.fromValue as? NSValue)?.sizeValue ?? .zero
            let origin = CGPoint(x: point.x - anchor.x * size.width, y: point.y - anchor.y * size.height)
            // An animation that the render server has yet has its start time; else the time of its act's pass.
            if counter.beginTime == 0, let time = began[act] { counter.beginTime = clip.convertTime(time, from: nil) }
            guard origin != .zero, counter.beginTime != 0 else { continue }
            counter.fromValue = NSValue(point: CGPoint(x: -origin.x, y: -origin.y))
            let name = "pane.commit.\(serial).kept.\(act)"
            mask.add(counter, forKey: name)
            moved.append((layer: mask, key: name))
        }
        return bands
    }

    /// Takes the cut from `host`: it is a pane of the layout again, or the motion ends.
    func uncut(_ host: PaneHostView) {
        guard let clip = host.clipView.layer, clip.mask?.name == Self.cutName else { return }
        clip.mask = nil
    }

    #if DEBUG
    /// The order that ``isUnderEachPane(_:unshown:)`` stands on: a pass that shows a change ends with each pane that
    /// left the layout under the others (``keepUnder(_:)``), or hidden. A pane that left the layout and shows in
    /// front of the others would cover a pane that no mask counts.
    func checkKept(on screen: ScreenContentView) {
        for case let host as PaneHostView in screen.subviews where host.isLeaving && !host.isHidden {
            assert(under.contains { $0.host === host }, "the pane \(host.pane) left the layout and shows in front after the pass that shows a change")
        }
    }
    #endif
}
