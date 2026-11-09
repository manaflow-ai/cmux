import AppKit
import CmuxNextDesign

/// `Slider`: a small native slider over `min...max`, snapped to `step` (a hundredth of the range when
/// absent, so a drag sends at most about a hundred `change {value}` events), its track in the scope's
/// primary ink. While a drag runs the app's echoes of earlier values do not move the thumb; the app's
/// value shows when the drag ends. Without `onChange` it only shows the app's value, disabled. The
/// range, step and snap are the SwiftUI renderer's (``AppSceneSlider``), so both send the same values.
final class AppSceneSliderNSView: AppSceneNodeNSView {
    private let slider = TrackingSlider()
    /// The last value sent or shown, so a drag sends each snapped value once.
    private var shown: Double = 0

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        slider.onDragEnd = { [weak self] in self?.showAppValue() }
        addSubview(slider)
    }

    private var range: ClosedRange<Double> { AppSceneSlider.range(node) }
    private var step: Double { AppSceneSlider.step(node, range) }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isEnabled = node.flag("onChange") && !node.flag("disabled")
        if !slider.isDragging { showAppValue() }
    }

    /// Shows the app's value, snapped.
    private func showAppValue() {
        shown = AppSceneSlider.snap(node.number("value") ?? range.lowerBound, range, step)
        slider.doubleValue = shown
    }

    @objc private func moved() {
        guard node.flag("onChange") else { return }
        let snapped = AppSceneSlider.snap(slider.doubleValue, range, step)
        guard snapped != shown else { return }
        shown = snapped
        send("change", ["value": .number(snapped)])
    }

    override func contentHeight(width: CGFloat) -> CGFloat { ceil(slider.fittingSize.height) }

    override func layoutContent(in rect: CGRect) {
        let height = ceil(slider.fittingSize.height)
        slider.frame = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height).integral
    }

    override func paint() { slider.trackFillColor = Palette.textPrimary }
}

/// An `NSSlider` that says when a drag runs: AppKit's `mouseDown` runs the whole tracking loop.
private final class TrackingSlider: NSSlider {
    private(set) var isDragging = false
    var onDragEnd: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        super.mouseDown(with: event)
        isDragging = false
        onDragEnd?()
    }
}
