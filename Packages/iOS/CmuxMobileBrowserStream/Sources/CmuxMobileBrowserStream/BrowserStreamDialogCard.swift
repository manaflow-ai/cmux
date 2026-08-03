#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileSupport
import UIKit

@MainActor
final class BrowserStreamDialogCard: UIView, UITextFieldDelegate {
    private let dialog: MobileBrowserDialogEvent
    private let respond: (MobileBrowserDialogRespondParameters) -> Void
    private var textField: UITextField?
    private var usernameField: UITextField?
    private var passwordField: UITextField?

    init(dialog: MobileBrowserDialogEvent, respond: @escaping (MobileBrowserDialogRespondParameters) -> Void) {
        self.dialog = dialog
        self.respond = respond
        super.init(frame: .zero)
        accessibilityIdentifier = "BrowserStreamDialog"
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        backgroundColor = UIColor.black.withAlphaComponent(0.48)
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        card.layer.cornerRadius = 24
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 16
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)

        let title = UILabel()
        title.font = .preferredFont(forTextStyle: .headline)
        title.numberOfLines = 0
        title.text = dialog.title ?? fallbackTitle
        stack.addArrangedSubview(title)

        if let detail = nonempty(dialog.message) ?? fallbackDetail {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            label.text = detail
            stack.addArrangedSubview(label)
        }
        if dialog.title == nil, let host = nonempty(dialog.host) {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = .tertiaryLabel
            label.text = host
            stack.addArrangedSubview(label)
        }

        addFields(to: stack)
        stack.addArrangedSubview(makeButtons())

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
        ])
    }

    private func addFields(to stack: UIStackView) {
        if dialog.kind == .httpBasicAuthentication {
            let username = makeField(
                placeholder: L10n.string("mobile.browserStream.dialog.username", defaultValue: "Username"),
                initial: dialog.textField?.initial ?? "",
                secure: false
            )
            username.textContentType = .username
            username.autocapitalizationType = .none
            username.autocorrectionType = .no
            usernameField = username
            stack.addArrangedSubview(username)

            let password = makeField(
                placeholder: dialog.textField?.placeholder
                    ?? L10n.string("mobile.browserStream.dialog.password", defaultValue: "Password"),
                initial: "",
                secure: true
            )
            password.textContentType = .password
            passwordField = password
            stack.addArrangedSubview(password)
        } else if let field = dialog.textField {
            let input = makeField(
                placeholder: field.placeholder
                    ?? L10n.string("mobile.browserStream.dialog.input", defaultValue: "Enter text"),
                initial: field.initial ?? "",
                secure: field.secure
            )
            if field.secure { input.textContentType = .password }
            textField = input
            stack.addArrangedSubview(input)
        }
    }

    private func makeField(placeholder: String, initial: String, secure: Bool) -> UITextField {
        let field = UITextField()
        field.borderStyle = .roundedRect
        field.backgroundColor = UIColor.quaternarySystemFill.withAlphaComponent(0.55)
        field.placeholder = placeholder
        field.text = initial
        field.isSecureTextEntry = secure
        field.delegate = self
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return field
    }

    private func makeButtons() -> UIView {
        let horizontal = dialog.buttons.count <= 2 && !dialog.buttons.contains { $0.label.count > 12 }
        let stack = UIStackView()
        stack.axis = horizontal ? .horizontal : .vertical
        stack.distribution = .fillEqually
        stack.spacing = horizontal ? 10 : 8
        for descriptor in dialog.buttons {
            var configuration: UIButton.Configuration
            switch descriptor.role {
            case .default:
                configuration = .filled()
            case .cancel, .destructive:
                configuration = .tinted()
            }
            configuration.title = descriptor.label
            if descriptor.role == .destructive {
                configuration.baseForegroundColor = .systemRed
            }
            let button = UIButton(configuration: configuration)
            button.accessibilityIdentifier = "BrowserStreamDialogButton-\(descriptor.id)"
            button.addAction(UIAction { [weak self] _ in self?.submit(descriptor) }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        return stack
    }

    private var fallbackTitle: String {
        if dialog.informational {
            return L10n.string("mobile.browserStream.dialog.needsMac", defaultValue: "Needs Your Mac")
        }
        if dialog.kind == .mediaCapturePermission {
            return L10n.string("mobile.browserStream.dialog.mediaTitle", defaultValue: "Media Access")
        }
        return L10n.string("mobile.browserStream.dialog.requestTitle", defaultValue: "Browser Request")
    }

    private var fallbackDetail: String? {
        if dialog.informational {
            return L10n.string("mobile.browserStream.dialog.needsMacDetail", defaultValue: "Complete this request on your Mac, or cancel it here.")
        }
        if dialog.kind == .mediaCapturePermission {
            return L10n.string("mobile.browserStream.dialog.mediaDetail", defaultValue: "This site wants to use your camera or microphone.")
        }
        return nil
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func submit(_ button: MobileBrowserDialogButton) {
        let responseText: String?
        if button.role == .cancel {
            responseText = nil
        } else if dialog.kind == .httpBasicAuthentication {
            responseText = (usernameField?.text ?? "") + "\0" + (passwordField?.text ?? "")
        } else if dialog.textField != nil {
            responseText = textField?.text ?? ""
        } else {
            responseText = nil
        }
        respond(MobileBrowserDialogRespondParameters(
            panelID: dialog.panelID,
            dialogID: dialog.dialogID,
            buttonID: button.id,
            text: responseText
        ))
    }
}
#endif
