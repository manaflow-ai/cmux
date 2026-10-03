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
        ScrollGeometry(contentHeight: scene.layout.contentHeight, minOffset: scene.minOffset,
                       pinnedOffset: scene.pinnedOffset, offset: scene.offset)
    }

    /// The host's scroll view moved (user, momentum or rubber band).
    public func hostScrolled(to offset: CGFloat) {
        scene.hostScroll(to: offset)
        afterViewportChange()
    }

    /// The compose field the host draws, in viewport points (top-left
    /// origin). `send` is true for the shrink after a send. The rows above
    /// follow with the shared field spring (`animateField`).
    public func setHostedField(_ frame: CGRect, send: Bool = false) {
        let oldTop = scene.fieldTop
        guard frame != scene.hostedField else { return }
        let begin = scene.now
        scene.hostedField = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let change = TranscriptChange.field(send: send)
        scene.placeMask(oldTop: oldTop, element: scene.motion(change.element), begin: begin)
        CATransaction.commit()
        guard scene.size.width > 0, oldTop != scene.fieldTop || send else { return }
        scene.commit(nil, change: change)
        publishScrollGeometryIfChanged()
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
        pendingSend = (intent, text, field)
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
