import AppKit

/// The gesture belongs to this list. Its app owns the order and sends new children after a move.
final class AppSceneReorderableNSView: AppSceneStackNSView, NSGestureRecognizerDelegate {
    private weak var source: AppSceneNodeNSView?
    private let insertion = CALayer()
    private lazy var pan = NSPanGestureRecognizer(target: self, action: #selector(reorder(_:)))

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        pan.delegate = self
        pan.delaysPrimaryMouseButtonEvents = true
        addGestureRecognizer(pan)
        insertion.isHidden = true
        insertion.zPosition = 1
        layer?.addSublayer(insertion)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        pan.isEnabled = node.flag("onMove") && !node.flag("disabled")
    }

    func gestureRecognizer(_ recognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown else { return true }
        let point = convert(event.locationInWindow, from: nil)
        source = childViews.first { $0.frame.contains(point) && $0.node.string("reorderKey") != nil && !$0.node.flag("disabled") }
        // Let inputs inside the row and an inner list handle their own drags.
        var hit = hitTest(superview?.convert(event.locationInWindow, from: nil) ?? point)
        while let view = hit, view !== self {
            if view is AppSceneReorderableNSView || view is NSSlider || view is NSTextView ||
                (view as? NSTextField)?.isEditable == true || (view as? AppSceneNodeNSView)?.node.flag("disabled") == true {
                source = nil
                break
            }
            hit = view.superview
        }
        return source != nil
    }

    /// The final index excludes the dragged child. A drop outside the list or in the same slot does nothing.
    func placement(of source: AppSceneNodeNSView, at point: CGPoint) -> (index: Int, edge: CGFloat)? {
        guard bounds.contains(point), childViews.contains(source) else { return nil }
        let others = childViews.filter { $0 !== source }
        let index = others.firstIndex { point.y < $0.frame.midY } ?? others.count
        guard childViews[index] !== source else { return nil }
        return (index, index < others.count ? others[index].frame.minY : others.last?.frame.maxY ?? 0)
    }

    @objc private func reorder(_ sender: NSPanGestureRecognizer) {
        let place = source.flatMap { placement(of: $0, at: sender.location(in: self)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        insertion.isHidden = true
        switch sender.state {
        case .began, .changed:
            if let place {
                insertion.backgroundColor = NSColor.controlAccentColor.cgColor
                insertion.frame = CGRect(x: 0, y: max(0, min(bounds.height - 1, place.edge)), width: bounds.width, height: 1)
                insertion.isHidden = false
            }
        case .ended:
            if let place, let key = source?.node.string("reorderKey") {
                send("move", ["id": .string(key), "index": .number(Double(place.index))])
            }
            source = nil
        default:
            source = nil
        }
    }
}
