import CmuxAgentChat

#if canImport(UIKit)
import UIKit

/// Native multiple-choice card that accepts at most one answer.
@MainActor
public final class ChatQuestionCardView: UIView {
    private let actions: ChatRowActions
    private var optionButtons: [UIButton] = []
    private var tappedIndex: Int?

    public init(question: ChatQuestion, actions: ChatRowActions) {
        self.actions = actions
        super.init(frame: .zero)

        let content = UIStackView()
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 10

        let prompt = UILabel()
        prompt.text = question.prompt
        prompt.font = .preferredFont(forTextStyle: .subheadline)
        prompt.textColor = .label
        prompt.numberOfLines = 0
        content.addArrangedSubview(prompt)

        if let selected = question.selectedOptionLabel {
            content.addArrangedSubview(receiptView(selected: selected))
        } else {
            let options = UIStackView()
            options.axis = .vertical
            options.spacing = 8
            for (index, option) in question.options.enumerated() {
                let button = optionButton(option: option, index: index)
                optionButtons.append(button)
                options.addArrangedSubview(button)
            }
            content.addArrangedSubview(options)
        }

        let card = UIView()
        card.layer.cornerRadius = 12
        card.layer.borderWidth = 1.5
        card.layer.borderColor = UIColor.systemBlue.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func optionButton(option: ChatQuestion.Option, index: Int) -> UIButton {
        let title: String
        if let detail = option.detail, !detail.isEmpty {
            title = "\(option.label)\n\(detail)"
        } else {
            title = option.label
        }
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.bordered()
        configuration.title = title
        configuration.titleAlignment = .leading
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 10
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .init(top: 8, leading: 12, bottom: 8, trailing: 12)
        button.configuration = configuration
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.numberOfLines = 0
        button.accessibilityIdentifier = "ChatQuestionOption\(index)"
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.choose(index) }, for: .primaryActionTriggered)
        return button
    }

    private func choose(_ index: Int) {
        guard tappedIndex == nil, optionButtons.indices.contains(index) else { return }
        tappedIndex = index
        for button in optionButtons {
            button.isEnabled = false
            button.alpha = 0.6
        }
        var configuration = optionButtons[index].configuration
        configuration?.showsActivityIndicator = true
        optionButtons[index].configuration = configuration
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        actions.answerOption(index)
    }

    private func receiptView(selected: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "checkmark"))
        icon.tintColor = .secondaryLabel
        let label = UILabel()
        label.text = selected
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [icon, label, UIView()])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        return stack
    }
}
#endif
