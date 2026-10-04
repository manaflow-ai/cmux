public import CmuxHomeCore
public import CoreGraphics
public import QuartzCore

/// Hosts with a native scroll view and a native compose field (the AppKit
/// host: NSScrollView, NSTextView in Liquid Glass). The render core keeps the
/// rows, their motion and the send morph; the host owns scrolling physics and
/// text editing and reports positions here.
extension HomeController {
    /// The transcript's scroll range in content points (y down). The host maps
    /// it to its document view: allowed offsets are `minOffset ... pinnedOffset`.
    public struct ScrollGeometry: Hashable, Sendable {
        public var contentHeight: CGFloat
        public var minOffset: CGFloat
        public var pinnedOffset: CGFloat
        public var offset: CGFloat
    }

    public var scrollGeometry: ScrollGeometry {
        ScrollGeometry(contentHeight: scene.layout.contentHeight * zoom, minOffset: scene.minOffset * zoom,
                       pinnedOffset: scene.pinnedOffset * zoom, offset: scene.offset * zoom)
    }

    /// The host's scroll view moved (user, momentum or rubber band).
    public func hostScrolled(to offset: CGFloat) {
        scene.hostScroll(to: offset / zoom)
        afterViewportChange()
    }

    /// The compose field the host draws, in viewport points (top-left
    /// origin). `send` is true for the shrink after a send. The rows above
    /// follow with the shared field spring (`animateField`).
    ///
    /// `animated: false` is for a move the host animates itself (the iOS
    /// keyboard: UIKit's curve, or the finger during an interactive
    /// dismissal): the rows and the clip move at once with no spring, and the
    /// result is how far the rows moved in the viewport (host points,
    /// old minus new, so positive when they moved up). The host shows the
    /// rows offset by that much and animates the offset to zero on its curve.
    @discardableResult
    public func setHostedField(_ hostFrame: CGRect, send: Bool = false, animated: Bool = true) -> CGFloat {
        let oldTop = scene.fieldTop
        hostedFieldInHost = hostFrame
        let frame = toDesign(hostFrame)
        guard frame != scene.hostedField else { return 0 }
        let begin = scene.now
        scene.hostedField = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let change = TranscriptChange.field(send: send)
        scene.placeMask(oldTop: oldTop, element: animated ? scene.motion(change.element) : nil, begin: begin)
        CATransaction.commit()
        guard scene.size.width > 0, oldTop != scene.fieldTop || send else { return 0 }
        let moved = scene.commit(nil, change: change, animated: animated)
        publishScrollGeometryIfChanged()
        return moved * zoom
    }

    /// Adds the shared field spring to a host layer's scalar key path (the
    /// glass height or position), so the field and the rows move together.
    public func animateField(_ layer: CALayer, keyPath: String, from: Double, to: Double, send: Bool) {
        let element = scene.motion(TranscriptChange.field(send: send).element)
        guard scene.motion.moves, from != to else { return }
        Animate.scalar(layer, keyPath, from: from, to: to, element, begin: scene.now)
    }

    /// A send from the host's own field: `text` is the draft, `field` its
    /// frame in viewport points (the morph flies from there).
    @discardableResult
    public func sendHosted(text: String, from field: CGRect) -> HomeIntent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let intent = HomeIntent(op: .sendMessage(conversation: conversation, parts: [.text(trimmed)]))
        pendingSend = (intent, text, toDesign(field))
        scene.pinned = true
        onIntent(intent)
        onAccessibilityChange()
        return intent
    }

    func publishScrollGeometryIfChanged() {
        let g = scrollGeometry
        guard g != lastPublishedGeometry else { return }
        lastPublishedGeometry = g
        onScrollGeometryChange(g)
    }
}

extension HomeController {
    /// Returns when no row bitmap is being drawn (tests and capture tools).
    public func bitmapsSettled() async {
        await scene.bitmaps.settled()
    }
}

extension HomeController {
    /// The shared field spring as a progress curve (0 -> 1) and its length,
    /// for host views AppKit must lay out every frame (the Liquid Glass field:
    /// its internal layers follow the model size, so the host animates the
    /// view's frame along this curve). Nil when motion is off.
    public func fieldCurve(send: Bool) -> (duration: Double, progress: @Sendable (Double) -> Double)? {
        guard scene.motion.moves else { return nil }
        let element = scene.motion(TranscriptChange.field(send: send).element)
        return (element.settleTime, { element.value($0, from: 0, to: 1) })
    }
}

extension HomeController {
    /// The first message row of `item` in content points (the coordinates
    /// of `scrollGeometry.offset`), or nil when the item is not loaded.
    /// Hosts scroll to `frame.minY - topInset` (top) or center it.
    public func contentFrame(for item: IdempotencyKey) -> CGRect? {
        let prefix = "part:\(item.rawValue):"
        guard let i = scene.model.rows.indices.first(where: { scene.model.rows[$0].spec.key.hasPrefix(prefix) && !scene.model.rows[$0].ghost })
        else { return nil }
        let spec = scene.model.rows[i].spec
        return toHost(CGRect(x: 0, y: scene.layout.contentTop(i), width: scene.size.width, height: spec.height))
    }

    /// Keyframes that move a host view from `old` to `new` along the shared
    /// field spring (one per 1/120 s), for hosts whose field view is laid
    /// out every frame (Liquid Glass on AppKit, UIKit views). Nil when
    /// motion is off.
    public func fieldKeyframes(from old: CGRect, to new: CGRect, send: Bool)
        -> (duration: Double, keyTimes: [Double], frames: [CGRect])? {
        guard let curve = fieldCurve(send: send), curve.duration > 0 else { return nil }
        let n = max(2, Int((curve.duration * 120).rounded(.up)) + 1)
        var times: [Double] = []
        var frames: [CGRect] = []
        for k in 0..<n {
            let t = Double(k) / Double(n - 1)
            let p = CGFloat(curve.progress(t * curve.duration))
            times.append(t)
            frames.append(CGRect(x: old.minX + (new.minX - old.minX) * p, y: old.minY + (new.minY - old.minY) * p,
                                 width: old.width + (new.width - old.width) * p, height: old.height + (new.height - old.height) * p))
        }
        frames[frames.count - 1] = new
        return (curve.duration, times, frames)
    }
}

/// Where `scroll(to:anchor:)` places a message.
public enum HomeScrollAnchor: Sendable, Hashable {
    /// The message's top just under the top inset.
    case top
    /// The message centered between the top inset and the compose field.
    case center
}

extension HomeController {
    /// Scrolls so `item` shows at `anchor` (a search hit, a reply jump).
    /// Returns false when the item is not loaded (the host loads its page
    /// first). The host's scroll view follows through `onScrollGeometryChange`.
    @discardableResult
    public func scroll(to item: IdempotencyKey, anchor: HomeScrollAnchor = .center) -> Bool {
        let prefix = "part:\(item.rawValue):"
        guard let i = scene.model.rows.indices.first(where: { scene.model.rows[$0].spec.key.hasPrefix(prefix) && !scene.model.rows[$0].ghost })
        else { return false }
        let top = scene.layout.contentTop(i)
        let height = scene.model.rows[i].spec.height
        let target: CGFloat = switch anchor {
        case .top: top - scene.topInset - 8
        case .center: top + height / 2 - (scene.topInset + scene.anchorY) / 2
        }
        let offset = scene.clamped(target)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.setOffset(offset)
        scene.layoutRows()
        scene.refreshVisibleRows()
        scene.pinned = scene.pinnedOffset - offset < 1
        CATransaction.commit()
        publishScrollGeometryIfChanged()
        afterViewportChange()
        return true
    }

    /// The item with sequence number `seq`, for hosts that hold a seq (search hits).
    public func item(withSeq seq: Seq) -> IdempotencyKey? {
        items.first { $0.seq == seq }?.key
    }
}
