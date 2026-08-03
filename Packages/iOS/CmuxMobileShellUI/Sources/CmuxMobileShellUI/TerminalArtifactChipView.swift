#if os(iOS)
import Foundation
import UIKit

/// Native terminal overlay that opens the visible-file gallery.
@MainActor
final class TerminalArtifactChipView: UIControl {
    private let effectView = UIVisualEffectView(effect: nil)
    private let stack = UIStackView()
    private let leadingImage = UIImageView()
    private let countLabel = UILabel()
    private let trailingImage = UIImageView()

    init(count: Int, onTap: @escaping @MainActor () -> Void) {
        super.init(frame: .zero)
        configureViews()
        addAction(UIAction { _ in onTap() }, for: .primaryActionTriggered)
        update(count: count)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12) {
                self.effectView.alpha = self.isHighlighted ? 0.72 : 1
                self.transform = self.isHighlighted
                    ? CGAffineTransform(scaleX: 0.97, y: 0.97)
                    : .identity
            }
        }
    }

    func update(count: Int) {
        let localizedCount = String(AttributedString(
            localized: "^[\(count) file](inflect: true)",
            bundle: .module
        ).characters)
        countLabel.text = localizedCount
        accessibilityValue = localizedCount
        invalidateIntrinsicContentSize()
    }

    private func configureViews() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "MobileTerminalArtifactChip"
        accessibilityLabel = String(
            localized: "terminal.artifact.chip.accessibility_label",
            defaultValue: "Open files in view",
            bundle: .module
        )

        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            effectView.effect = effect
        } else {
            effectView.effect = UIBlurEffect(style: .systemMaterial)
            effectView.layer.borderWidth = 0.5
            effectView.layer.borderColor = UIColor.label.withAlphaComponent(0.08).cgColor
            effectView.layer.shadowColor = UIColor.black.cgColor
            effectView.layer.shadowOpacity = 0.12
            effectView.layer.shadowRadius = 6
            effectView.layer.shadowOffset = CGSize(width: 0, height: 2)
        }
        effectView.isUserInteractionEnabled = false
        effectView.clipsToBounds = true
        effectView.layer.cornerRadius = 22
        effectView.layer.cornerCurve = .continuous
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)

        leadingImage.image = UIImage(
            systemName: "photo.on.rectangle",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        )
        leadingImage.tintColor = .label
        leadingImage.contentMode = .scaleAspectFit

        let baseFont = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .semibold
        )
        countLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: baseFont)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = .label

        trailingImage.image = UIImage(
            systemName: "chevron.up",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
        )
        trailingImage.tintColor = .secondaryLabel
        trailingImage.contentMode = .scaleAspectFit

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0,
            leading: 14,
            bottom: 0,
            trailing: 14
        )
        stack.addArrangedSubview(leadingImage)
        stack.addArrangedSubview(countLabel)
        stack.addArrangedSubview(trailingImage)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }
}
#endif
