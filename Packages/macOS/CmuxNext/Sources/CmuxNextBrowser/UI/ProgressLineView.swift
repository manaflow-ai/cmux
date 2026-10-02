import AppKit
import CmuxNextDesign

/// Thin gray load progress line under the toolbar.
final class ProgressLineView: NSView {
    private let bar = CALayer()
    private var progress: Double = 0
    private var visible = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(bar)
        bar.anchorPoint = .zero
        bar.opacity = 0
        updateColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(progress: Double, visible: Bool) {
        let wasVisible = self.visible
        self.progress = visible ? progress : (wasVisible ? 1 : 0)
        self.visible = visible
        let apply = {
            self.layoutBar()
            if visible {
                self.bar.opacity = 1
            } else if wasVisible {
                self.bar.opacity = 0
            }
        }
        // A bar that just appeared starts in place; later progress glides.
        if !wasVisible && visible {
            Motion.transaction(nil, apply)
        } else {
            Motion.transaction(spring: .move, apply)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutBar()
        CATransaction.commit()
    }

    private func layoutBar() {
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        performWithTheme {
            bar.backgroundColor = Palette.focusRing.withAlphaComponent(0.8).cgColor
        }
    }
}
