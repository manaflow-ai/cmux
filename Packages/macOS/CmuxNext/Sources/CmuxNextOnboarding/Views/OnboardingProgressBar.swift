import AppKit
import CmuxNextDesign

/// The thin bar over the import explainers: how far the import flow is
/// (OnboardingModel.flowProgress). Theme ink on a hover-fill track, never
/// the accent blue.
final class OnboardingProgressBar: ThemedView {
    private let bar = ThemedView()
    private var widthConstraint: NSLayoutConstraint?

    var value: Double = 0 {
        didSet {
            guard value != oldValue else { return }
            applyValue()
        }
    }

    init() {
        super.init(frame: .zero)
        fill = { Palette.hoverFill }
        cornerRadius = 2
        bar.fill = { Palette.textPrimary }
        bar.cornerRadius = 2
        addSubview(bar)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 4),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        applyValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyValue() {
        widthConstraint?.isActive = false
        widthConstraint = bar.widthAnchor.constraint(equalTo: widthAnchor, multiplier: max(0.001, min(1, value)))
        widthConstraint?.isActive = true
        setAccessibilityValue(NSNumber(value: value))
    }
}
