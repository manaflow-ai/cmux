import AppKit
import CmuxNextDesign

/// The drag panel's arrow up to the System Settings list: a solid arrow in
/// the system accent color with a white outline, so it reads over the panel's
/// glass in light and dark, that bobs gently while the panel waits for the
/// drag (`Motion.indicators`, `MotionLoop.nudge`). With loops off (the
/// category off, animation speed off, Reduce Motion) it stays still.
final class HelperPanelArrow: NSImageView {
    /// Tall enough that the head stands above the line of text and the shaft runs beside it.
    static let pointSize: CGFloat = 26
    /// The white outline, drawn over the fill in the same shape (it moves with the arrow's layer).
    private let outline = NSImageView()
    /// Points of vertical travel in one bob.
    static let travel: CGFloat = 4
    static let bounceKey = "cmux.helperPanel.arrowBounce"

    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "arrowshape.up.fill", accessibilityDescription: nil)
        symbolConfiguration = .init(pointSize: Self.pointSize, weight: TypeScale.regular)
        contentTintColor = .controlAccentColor
        imageScaling = .scaleNone
        outline.image = NSImage(systemSymbolName: "arrowshape.up", accessibilityDescription: nil)
        outline.symbolConfiguration = .init(pointSize: Self.pointSize, weight: TypeScale.regular)
        outline.contentTintColor = .white
        outline.imageScaling = .scaleNone
        outline.translatesAutoresizingMaskIntoConstraints = false
        outline.setAccessibilityElement(false)
        addSubview(outline)
        NSLayoutConstraint.activate([
            outline.centerXAnchor.constraint(equalTo: centerXAnchor), outline.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Starts the bob (when the motion gate allows a loop) or stops it.
    func bounce(_ on: Bool) {
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.bounceKey)
        guard on, let animation = Motion.indicators.nudgeAnimation(travel: Self.travel) else { return }
        layer.add(animation, forKey: Self.bounceKey)
    }

    /// Whether the bob runs now.
    var isBouncing: Bool { layer?.animation(forKey: Self.bounceKey) != nil }
}
