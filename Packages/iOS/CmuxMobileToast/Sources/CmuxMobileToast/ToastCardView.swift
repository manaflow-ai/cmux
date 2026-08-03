#if canImport(UIKit)
import CmuxMobileSupport
import UIKit

@MainActor
final class ToastCardView: UIView, UIGestureRecognizerDelegate {
    private let effectView = UIVisualEffectView()
    private let contentStack = UIStackView()
    private var toast: Toast
    private let dismiss: () -> Void

    init(toast: Toast, dismiss: @escaping () -> Void) {
        self.toast = toast
        self.dismiss = dismiss
        super.init(frame: .zero)
        setupChrome()
        configure(with: toast)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = toast.title == nil ? bounds.height / 2 : 22
        effectView.layer.cornerRadius = layer.cornerRadius
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss()
        return true
    }

    func configure(with toast: Toast) {
        self.toast = toast
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if let symbol = toast.resolvedSystemImage {
            contentStack.addArrangedSubview(makeIcon(symbol))
        }
        contentStack.addArrangedSubview(makeTextStack())
        if let action = toast.action {
            contentStack.addArrangedSubview(makeActionButton(action))
        }
        contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: toast.title == nil ? 9 : 11,
            leading: toast.resolvedSystemImage == nil ? 16 : 9,
            bottom: toast.title == nil ? 9 : 11,
            trailing: toast.action == nil ? 16 : 9
        )
        accessibilityLabel = [toast.title, toast.message].compactMap { $0 }.joined(separator: ". ")
        var actions = [UIAccessibilityCustomAction(
            name: L10n.string("mobile.common.dismiss", defaultValue: "Dismiss"),
            actionHandler: { [weak self] _ in self?.dismiss(); return true }
        )]
        if let action = toast.action {
            actions.insert(UIAccessibilityCustomAction(
                name: action.label,
                actionHandler: { [weak self] _ in
                    action.handler()
                    self?.dismiss()
                    return true
                }
            ), at: 0)
        }
        accessibilityCustomActions = actions
        setNeedsLayout()
    }

    private func setupChrome() {
        clipsToBounds = false
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = UIColor.label.withAlphaComponent(0.10).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 6)

        if UIAccessibility.isReduceTransparencyEnabled {
            effectView.effect = nil
            effectView.backgroundColor = .secondarySystemBackground
        } else if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            effectView.effect = glass
        } else {
            effectView.effect = UIBlurEffect(style: .systemMaterial)
        }
        effectView.clipsToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 10
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        effectView.contentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapCard))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
        isAccessibilityElement = true
        accessibilityIdentifier = "MobileToast"
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }

    @objc private func didTapCard() { dismiss() }

    private func makeIcon(_ symbol: String) -> UIView {
        let container = UIView()
        container.backgroundColor = toast.style.uiTint.withAlphaComponent(0.15)
        container.layer.cornerRadius = 13
        container.widthAnchor.constraint(equalToConstant: 26).isActive = true
        container.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let image = UIImageView(image: UIImage(systemName: symbol))
        image.tintColor = toast.style.uiTint
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        image.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(image)
        NSLayoutConstraint.activate([
            image.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeTextStack() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        if let title = toast.title {
            let label = UILabel()
            label.text = title
            label.font = .preferredFont(forTextStyle: .footnote).withWeight(.semibold)
            label.numberOfLines = 2
            stack.addArrangedSubview(label)
        }
        let message = UILabel()
        message.text = toast.message
        message.font = .preferredFont(forTextStyle: toast.title == nil ? .subheadline : .footnote)
        message.textColor = toast.title == nil ? .label : .secondaryLabel
        message.numberOfLines = 4
        stack.addArrangedSubview(message)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func makeActionButton(_ action: Toast.Action) -> UIButton {
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .tinted()
        }
        configuration.title = action.label
        configuration.buttonSize = .small
        configuration.baseForegroundColor = toast.style.actionUITint
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "MobileToastActionButton"
        button.addAction(UIAction { [weak self] _ in
            action.handler()
            self?.dismiss()
        }, for: .touchUpInside)
        return button
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

extension Toast.Style {
    var uiTint: UIColor {
        switch self {
        case .info: .secondaryLabel
        case .success: .systemGreen
        case .warning: .systemOrange
        case .failure: .systemRed
        }
    }

    var actionUITint: UIColor? {
        switch self {
        case .info: nil
        case .success, .warning, .failure: uiTint
        }
    }
}
#endif
