#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Stand-in for New Message while no host wires `onForward`: a sheet titled
/// "New Message" with an empty To: line and the forwarded text in the
/// message field. The real compose sheet (recipients, sending) replaces it by
/// setting `ConversationViewController.onForward`.
final class ConversationForwardPlaceholderController: UIViewController {
    let draft: ConversationForwardDraft
    let messageField = UITextView()

    init(draft: ConversationForwardDraft) {
        self.draft = draft
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ConversationTheme.background
        title = String(localized: "conversation.forward.title", defaultValue: "New Message", bundle: .module)
        let cancel = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        cancel.accessibilityLabel = String(localized: "conversation.select.cancel", defaultValue: "Cancel", bundle: .module)
        navigationItem.rightBarButtonItem = cancel

        let toLabel = UILabel()
        toLabel.text = String(localized: "conversation.forward.to", defaultValue: "To:", bundle: .module)
        toLabel.font = .preferredFont(forTextStyle: .body)
        toLabel.textColor = .secondaryLabel
        toLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toLabel)

        messageField.text = draft.draftText
        messageField.font = .preferredFont(forTextStyle: .body)
        messageField.adjustsFontForContentSizeCategory = true
        messageField.backgroundColor = .secondarySystemBackground
        messageField.layer.cornerRadius = 20
        messageField.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        messageField.accessibilityLabel = String(localized: "conversation.forward.message", defaultValue: "Message", bundle: .module)
        messageField.accessibilityIdentifier = "conversation.forward.message"
        messageField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageField)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            toLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            toLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 30),
            messageField.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            messageField.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            messageField.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            messageField.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            {
                let preferred = messageField.heightAnchor.constraint(equalToConstant: 120)
                preferred.priority = .defaultLow
                return preferred
            }(),
            messageField.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor, multiplier: 0.5),
        ])
    }
}

extension ConversationViewController {
    func presentForwardPlaceholder(_ draft: ConversationForwardDraft) {
        let sheet = UINavigationController(rootViewController: ConversationForwardPlaceholderController(draft: draft))
        sheet.modalPresentationStyle = .pageSheet
        present(sheet, animated: true)
    }
}
#endif
