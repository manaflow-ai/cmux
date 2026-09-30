import AppKit
import CmuxNextDesign

/// Glass bar that asks the first pending prompt of the tab: a permission
/// request or a JavaScript alert, confirm, or text input.
final class PromptBarView: NSView {
    private(set) var prompt: BrowserPrompt?
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let inputField = ChromeTextField()
    private let buttons = NSStackView()
    private let stack = NSStackView()
    private let density = DensityBinding()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        messageLabel.textColor = Palette.textPrimary
        messageLabel.maximumNumberOfLines = 6

        inputField.wantsLayer = true
        inputField.delegate = self
        applyColors()

        buttons.setHuggingPriority(.required, for: .horizontal)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(inputField)
        stack.addArrangedSubview(buttons)

        let content = OverlayBackingView()
        content.addSubview(stack)
        let glass = Glass.makePanel(content: content, style: .regular, cornerRadius: BrowserMetrics.overlayCornerRadius)
        addSubview(glass)
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
            density.bind(widthAnchor.constraint(greaterThanOrEqualToConstant: 0)) { BrowserMetrics.promptMinWidth },
            density.bind(inputField.widthAnchor.constraint(equalTo: stack.widthAnchor)) { -BrowserMetrics.overlayPadding * 2 },
            density.bind(inputField.heightAnchor.constraint(equalToConstant: 0)) { BrowserMetrics.controlHeight },
        ])
        density.update { [unowned self] in
            let padding = BrowserMetrics.overlayPadding
            messageLabel.font = BrowserMetrics.bodyFont
            messageLabel.preferredMaxLayoutWidth = BrowserMetrics.promptMaxWidth - padding * 2
            inputField.layer?.cornerRadius = BrowserMetrics.controlCornerRadius
            buttons.spacing = BrowserMetrics.itemSpacing
            stack.spacing = padding
            stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
            glass.cornerRadius = BrowserMetrics.overlayCornerRadius
        }
        density.start()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            inputField.layer?.backgroundColor = Palette.chromeBackground.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ prompt: BrowserPrompt) {
        guard prompt !== self.prompt else { return }
        self.prompt = prompt
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        inputField.isHidden = true

        switch prompt.kind {
        case .permission(let kind):
            messageLabel.stringValue = switch kind {
            case .camera: Strings.permissionCamera(prompt.origin)
            case .microphone: Strings.permissionMicrophone(prompt.origin)
            case .cameraAndMicrophone: Strings.permissionCameraAndMicrophone(prompt.origin)
            }
            addButton(Strings.dontAllow, prominent: false, response: .deny)
            addButton(Strings.allow, prominent: true, response: .allow)
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
        }
        if !inputField.isHidden {
            window?.makeFirstResponder(inputField)
        }
    }

    private func addButton(_ title: String, prominent: Bool, response: BrowserPromptResponse?) {
        let button = PromptResponseButton(title: title, prominent: prominent, action: #selector(respond(_:)), target: self)
        button.response = response
        buttons.addArrangedSubview(button)
    }

    @objc private func respond(_ sender: PromptResponseButton) {
        prompt?.respond(sender.response ?? .text(inputField.stringValue))
    }
}

extension PromptBarView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            prompt?.respond(.text(inputField.stringValue))
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
