import AppKit
import CmuxNextDesign

/// Glass bar that asks the first pending prompt of the tab: a permission
/// request, a JavaScript alert, confirm, or text input, or HTTP
/// authentication (user name and password).
final class PromptBarView: NSView {
    private(set) var prompt: BrowserPrompt?
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let inputField = ChromeTextField()
    /// HTTP authentication fields.
    let userField = ChromeTextField()
    let passwordField = ChromeSecureTextField()
    private let buttons = NSStackView()
    private let stack = NSStackView()
    private let density = DensityBinding()
    /// The bar's material: glass, or opaque under Reduce Transparency.
    private(set) var glass: OverlaySurfaceView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        messageLabel.maximumNumberOfLines = 6

        for field in [inputField, userField, passwordField] as [NSTextField] {
            field.wantsLayer = true
            field.delegate = self
        }
        userField.setPlaceholder(Strings.authUserName)
        passwordField.setPlaceholder(Strings.authPassword)
        applyColors()

        buttons.setHuggingPriority(.required, for: .horizontal)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(inputField)
        stack.addArrangedSubview(userField)
        stack.addArrangedSubview(passwordField)
        stack.addArrangedSubview(buttons)

        let content = OverlayBackingView()
        content.addSubview(stack)
        let glass = Glass.makeOverlayPanel(content: content, cornerRadius: BrowserMetrics.overlayCornerRadius)
        addSubview(glass)
        self.glass = glass
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            density.bind(widthAnchor.constraint(lessThanOrEqualToConstant: 0)) { BrowserMetrics.promptMaxWidth },
            // Preferred minimum: a pane narrower than it narrows the bar.
            density.bind(widthAnchor.constraint(greaterThanOrEqualToConstant: 0).prioritized(.init(450))) { BrowserMetrics.promptMinWidth },
        ])
        for field in [inputField, userField, passwordField] as [NSTextField] {
            NSLayoutConstraint.activate([
                density.bind(field.widthAnchor.constraint(equalTo: stack.widthAnchor)) { -BrowserMetrics.overlayPadding * 2 },
                density.bind(field.heightAnchor.constraint(equalToConstant: 0)) { BrowserMetrics.controlHeight },
            ])
        }
        density.update { [unowned self] in
            let padding = BrowserMetrics.overlayPadding
            messageLabel.font = BrowserMetrics.bodyFont
            messageLabel.preferredMaxLayoutWidth = BrowserMetrics.promptMaxWidth - padding * 2
            for field in [inputField, userField, passwordField] as [NSTextField] {
                field.layer?.cornerRadius = BrowserMetrics.controlCornerRadius
            }
            buttons.spacing = BrowserMetrics.itemSpacing
            stack.spacing = padding
            stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
            glass.cornerRadius = BrowserMetrics.overlayCornerRadius
        }
        density.start()
    }

    /// Lines the message takes (tests).
    var messageLineCount: Int {
        let line = NSLayoutManager().defaultLineHeight(for: messageLabel.font ?? BrowserMetrics.bodyFont)
        return max(1, Int((messageLabel.intrinsicContentSize.height / line).rounded()))
    }

    /// The message wraps at the bar's real width (a narrower pane makes it
    /// narrower than `promptMaxWidth`), or its last lines are cut off.
    override func layout() {
        super.layout()
        let width = messageLabel.frame.width
        if width > 0, abs(messageLabel.preferredMaxLayoutWidth - width) > 0.5 {
            messageLabel.preferredMaxLayoutWidth = width
            needsLayout = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            for field in [inputField, userField, passwordField] as [NSTextField] {
                field.layer?.backgroundColor = Palette.chromeBackground.cgColor
            }
            messageLabel.textColor = Palette.textPrimary
            glass?.applyTheme()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ prompt: BrowserPrompt) {
        guard prompt !== self.prompt else { return }
        self.prompt = prompt
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        inputField.isHidden = true
        userField.isHidden = true
        passwordField.isHidden = true

        switch prompt.kind {
        case .permission(let kind):
            messageLabel.stringValue = switch kind {
            case .camera: Strings.permissionCamera(prompt.origin)
            case .microphone: Strings.permissionMicrophone(prompt.origin)
            case .cameraAndMicrophone: Strings.permissionCameraAndMicrophone(prompt.origin)
            }
            // Permission prompt answers: never, this time, while visiting.
            addButton(PageInfoStrings.promptNeverAllow, prominent: false, response: .deny)
            addButton(PageInfoStrings.promptAllowThisTime, prominent: false, response: .allowOnce)
            addButton(PageInfoStrings.promptAllowWhileVisiting, prominent: true, response: .allow)
        case .alert(let message):
            messageLabel.stringValue = "\(Strings.dialogFrom(prompt.origin))\n\(message)"
            addButton(Strings.ok, prominent: true, response: .accept)
        case .confirm(let message):
            messageLabel.stringValue = "\(Strings.dialogFrom(prompt.origin))\n\(message)"
            addButton(Strings.cancel, prominent: false, response: .cancel)
            addButton(Strings.ok, prominent: true, response: .accept)
        case .textInput(let message, let defaultText):
            messageLabel.stringValue = "\(Strings.dialogFrom(prompt.origin))\n\(message)"
            inputField.stringValue = defaultText ?? ""
            inputField.isHidden = false
            addButton(Strings.cancel, prominent: false, response: .cancel)
            addButton(Strings.ok, prominent: true, response: nil)
        case .credentials(let host, let realm):
            messageLabel.stringValue = realm.map { Strings.authPromptRealm(host: host, realm: $0) } ?? Strings.authPrompt(host: host)
            userField.stringValue = ""
            passwordField.stringValue = ""
            userField.isHidden = false
            passwordField.isHidden = false
            addButton(Strings.cancel, prominent: false, response: .cancel)
            addButton(Strings.authSignIn, prominent: true, response: nil)
        }
        if !inputField.isHidden {
            window?.makeFirstResponder(inputField)
        } else if !userField.isHidden {
            window?.makeFirstResponder(userField)
        }
    }

    /// The answer of the prompt's prominent button: the typed text, or the
    /// typed user name and password.
    func submit() {
        guard let prompt else { return }
        if case .credentials = prompt.kind {
            prompt.respond(.credentials(user: userField.stringValue, password: passwordField.stringValue))
        } else {
            prompt.respond(.text(inputField.stringValue))
        }
    }

    private func addButton(_ title: String, prominent: Bool, response: BrowserPromptResponse?) {
        let button = PromptResponseButton(title: title, prominent: prominent, action: #selector(respond(_:)), target: self)
        button.response = response
        buttons.addArrangedSubview(button)
    }

    @objc private func respond(_ sender: PromptResponseButton) {
        if let response = sender.response { prompt?.respond(response) } else { submit() }
    }
}

extension PromptBarView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            prompt?.respond(.cancel)
            return true
        default:
            return false
        }
    }
}

final class PromptResponseButton: ChromeTextButton {
    var response: BrowserPromptResponse?
}
