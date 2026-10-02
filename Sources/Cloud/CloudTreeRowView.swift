import AppKit

/// Row view drawing the Cloud sidebar's shared highlight (`CloudTreeHoverStyle`):
/// a rounded fill inset from the edges, for selection and for hover. The
/// hover fill is a layer so it can fade in and out; the cell decides when a
/// row shows it (`CloudTreeCellView`).
@MainActor
final class CloudTreeRowView: NSTableRowView {
    /// Hover and reorder state belong to the cell and outline, so row views
    /// can use AppKit's reuse pool without retaining a previous item.
    static func reusable(in outlineView: NSOutlineView) -> CloudTreeRowView {
        let identifier = NSUserInterfaceItemIdentifier("CloudTreeRow")
        let row = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? CloudTreeRowView) ?? CloudTreeRowView()
        row.identifier = identifier
        return row
    }

    private let hoverLayer = CALayer()

    /// Where the highlight starts, set by the outline from the row's level.
    var highlightLeading: CGFloat = CloudTreeHoverStyle.horizontalInset {
        didSet { if highlightLeading != oldValue { needsLayout = true; needsDisplay = true } }
    }

    /// True while the pointer is over this row and the row takes the hover fill.
    private(set) var isHoverHighlighted = false

    /// Shows or hides the hover fill. A reload that keeps the pointer on the
    /// same row passes `animated: false`, so the fill never flickers.
    func setHoverHighlighted(_ highlighted: Bool, animated: Bool) {
        guard highlighted != isHoverHighlighted else { return }
        isHoverHighlighted = highlighted
        updateHoverLayer(animated: animated)
    }

    override var isSelected: Bool {
        didSet { updateHoverLayer(animated: false) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        hoverLayer.opacity = 0
        hoverLayer.cornerRadius = CloudTreeHoverStyle.cornerRadius
        hoverLayer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if hoverLayer.superlayer == nil, let layer {
            layer.insertSublayer(hoverLayer, at: 0)
            updateHoverColor()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = highlightRect
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHoverColor()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setHoverHighlighted(false, animated: false)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = highlightRect
        let radius = CloudTreeHoverStyle.cornerRadius
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        // Gray in both focus states (no accent blue); keyboard focus reads as a
        // slightly stronger shade.
        NSColor.labelColor.withAlphaComponent(
            isKeyboardFocusActive ? CloudTreeHoverStyle.focusedSelectedOpacity : CloudTreeHoverStyle.selectedOpacity
        ).setFill()
        path.fill()
    }

    private var highlightRect: NSRect {
        let leading = min(highlightLeading, max(0, bounds.width - CloudTreeHoverStyle.horizontalInset))
        return NSRect(
            x: bounds.minX + leading,
            y: bounds.minY + CloudTreeHoverStyle.verticalInset,
            width: max(0, bounds.width - leading - CloudTreeHoverStyle.horizontalInset),
            height: max(0, bounds.height - 2 * CloudTreeHoverStyle.verticalInset)
        )
    }

    private func updateHoverColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hoverLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(CloudTreeHoverStyle.hoverOpacity).cgColor
        }
    }

    private func updateHoverLayer(animated: Bool) {
        let visible = isHoverHighlighted && !isSelected
        CATransaction.begin()
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            CATransaction.setAnimationDuration(visible ? CloudTreeHoverStyle.fadeIn : CloudTreeHoverStyle.fadeOut)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        hoverLayer.opacity = visible ? 1 : 0
        CATransaction.commit()
    }
    private var isKeyboardFocusActive: Bool {
        var view = superview
        while let candidate = view {
            if let outlineView = candidate as? NSOutlineView {
                return window?.isKeyWindow == true && window?.firstResponder === outlineView
            }
            view = candidate.superview
        }
        return false
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        // The gray highlight keeps normal label colors; .emphasized would flip
        // the text to white as if on an accent fill.
        .normal
    }
}
