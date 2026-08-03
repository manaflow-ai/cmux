#if canImport(UIKit)
import UIKit

/// Native escape hatch for an alt-screen terminal program.
@MainActor
public final class TerminalInteractiveCardView: UIView {
    public init(command: String, onOpenTerminal: @escaping @MainActor () -> Void) {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.055, alpha: 1)
        layer.cornerRadius = 12
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.cgColor

        let commandLabel = UILabel()
        commandLabel.text = "❯ \(command.isEmpty ? " " : command)"
        commandLabel.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        commandLabel.textColor = UIColor(white: 0.88, alpha: 1)
        commandLabel.lineBreakMode = .byTruncatingMiddle
        commandLabel.numberOfLines = 1

        let message = UILabel()
        message.text = String(
            localized: "chat.terminal.interactive",
            defaultValue: "Interactive program, open the full terminal",
            bundle: .module
        )
        message.font = .preferredFont(forTextStyle: .footnote)
        message.textColor = .secondaryLabel
        message.numberOfLines = 0

        let messageRow = UIStackView(arrangedSubviews: [UIImageView(image: UIImage(systemName: "macwindow")), message])
        messageRow.axis = .horizontal
        messageRow.alignment = .center
        messageRow.spacing = 8
        messageRow.tintColor = .secondaryLabel

        let button = UIButton(type: .system)
        button.setTitle(
            String(
                localized: "chat.terminal.open_in_terminal",
                defaultValue: "Open in terminal",
                bundle: .module
            ),
            for: .normal
        )
        button.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = "TerminalInteractiveOpenButton"
        button.accessibilityLabel = String(
            localized: "chat.terminal.interactive.accessibility",
            defaultValue: "\(command) is an interactive program. Open the full terminal.",
            bundle: .module
        )
        button.addAction(UIAction { _ in onOpenTerminal() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [commandLabel, messageRow, button])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
