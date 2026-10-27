import AppKit
import CmuxNextDesign

/// Glass bar that asks the first pending prompt of the tab: a permission
/// request (camera, microphone, location, notifications, downloads), a JavaScript alert, confirm, or text input, HTTP
/// authentication (user name and password), or a link to another app
/// (Open, with "Always allow" for the site).
final class PromptBarView: ChromeFrameView {
    private(set) var prompt: BrowserPrompt?
    private let messageLabel = ChromeLabel(wrappingLabelWithString: "")
    private let inputField = ChromeTextField()
    /// HTTP authentication fields.
    let userField = ChromeTextField()
    let passwordField = ChromeSecureTextField()
    /// "Always allow" of a link to another app.
    private let alwaysCheck = ThemedCheckbox(checkboxWithTitle: "", target: nil, action: nil)
    /// The answer buttons of the prompt shown, in reading order.
    private var buttons: [PromptResponseButton] = []
    /// The bar's content (the glass's), where the column lays out.
    private let content = OverlayBackingView()
    private let density = DensityBinding()
    /// The bar's material: glass, or opaque under Reduce Transparency.
    private(set) var glass: OverlaySurfaceView?
    /// The room `followRoom()` last saw.
    private var measuredRoom: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)

        messageLabel.maximumNumberOfLines = 6

        for field in [inputField, userField, passwordField] as [NSTextField] {
            field.wantsLayer = true
            field.delegate = self
        }
        userField.setPlaceholder(Strings.authUserName)
        passwordField.setPlaceholder(Strings.authPassword)
        applyColors()

        for view in [messageLabel, inputField, userField, passwordField, alwaysCheck] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            content.addSubview(view)
        }
        let glass = Glass.makeOverlayPanel(content: content, cornerRadius: BrowserMetrics.overlayCornerRadius)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        addSubview(glass)
        self.glass = glass
        density.update { [weak self] in
            guard let self else { return }
            messageLabel.font = BrowserMetrics.bodyFont
            alwaysCheck.font = BrowserMetrics.bodyFont
            for field in [inputField, userField, passwordField] as [NSTextField] {
                field.layer?.cornerRadius = BrowserMetrics.controlCornerRadius
            }
            glass.cornerRadius = BrowserMetrics.overlayCornerRadius
            contentDidChange()
        }
        density.start(in: self)
    }

    /// The bar: the message, the shown fields (as wide as the bar), the
    /// "Always allow" check and the answer row, leading, with the overlay
    /// padding around and between them; at most `promptMaxWidth` wide and,
    /// room permitting, at least `promptMinWidth`.
    var cardLayout: OverlayCardLayout {
        let padding = BrowserMetrics.overlayPadding
        return OverlayCardLayout(column: ChromeColumnLayout(spacing: padding, insets: ChromeInsets(all: padding),
                                                            alignment: .leading, rightToLeft: laysOutRightToLeft),
                                 minWidth: BrowserMetrics.promptMinWidth, maxWidth: BrowserMetrics.promptMaxWidth)
    }

    private var items: [ChromeColumnItem] {
        var items: [ChromeColumnItem] = [.view(messageLabel)]
        for field in [inputField, userField, passwordField] as [NSView] where !field.isHidden {
            items.append(.fill(field, height: BrowserMetrics.controlHeight))
        }
        if !alwaysCheck.isHidden { items.append(.view(alwaysCheck)) }
        items.append(.row(buttons, ChromeRowLayout(spacing: BrowserMetrics.itemSpacing, rightToLeft: laysOutRightToLeft)))
        return items
    }

    /// The bar's size in a room `width` wide: the message wraps at the width
    /// the bar takes there, never at a width an earlier message left.
    func size(fittingWidth width: CGFloat) -> CGSize {
        cardLayout.measure(items, room: width)
    }

    /// The room the bar may take: its container less the overlay insets
    /// (the widest bar before it has one).
    private var room: CGFloat {
        superview.map { $0.bounds.width - BrowserMetrics.overlayInset * 2 } ?? BrowserMetrics.promptMaxWidth
    }

    /// Its size in its container's room, for an owner that places it with
    /// constraints.
    override var intrinsicContentSize: NSSize { size(fittingWidth: room) }

    /// The owner calls this from its `layout()` before it solves its
    /// subviews: a container that got wider or narrower measures the bar
    /// again in the new room.
    func followRoom() {
        let room = self.room
        guard room != measuredRoom else { return }
        measuredRoom = room
        invalidateIntrinsicContentSize() // invalidate: the container's width changed since the last measure
    }

    override func layout() {
        super.layout()
        if let glass, glass.frame != bounds { glass.frame = bounds }
        cardLayout.column.layout(items, in: CGRect(origin: .zero, size: bounds.size))
    }

    /// The message, the fields or the answers changed: the column lays out
    /// again and the bar's size is measured again.
    private func contentDidChange() {
        invalidateIntrinsicContentSize() // invalidate: the shown content changed (callers change it first)
        needsLayout = true // invalidate: as above
    }

    // visibility-walk-allow: three field layer colors, a text color and the glass tint in the theme scope, no layout or text measure; cheaper than a deferral
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
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        inputField.isHidden = true
        userField.isHidden = true
        passwordField.isHidden = true
        alwaysCheck.isHidden = true

        switch prompt.kind {
        case .permission(let kind):
            messageLabel.stringValue = switch kind {
            case .camera: Strings.permissionCamera(prompt.origin)
            case .microphone: Strings.permissionMicrophone(prompt.origin)
            case .cameraAndMicrophone: Strings.permissionCameraAndMicrophone(prompt.origin)
            case .automaticDownloads: Strings.permissionAutomaticDownloads(prompt.origin)
            case .location: Strings.permissionLocation(prompt.origin)
            case .notifications: Strings.permissionNotifications(prompt.origin)
            }
            if [.automaticDownloads, .location, .notifications].contains(kind) {
                // Chrome's question: Block or Allow, remembered for the site.
                addButton(PageInfoStrings.block, prominent: false, response: .deny)
                addButton(PageInfoStrings.allow, prominent: true, response: .allow)
            } else {
                // Permission prompt answers: never, this time, while visiting.
                addButton(PageInfoStrings.promptNeverAllow, prominent: false, response: .deny)
                addButton(PageInfoStrings.promptAllowThisTime, prominent: false, response: .allowOnce)
                addButton(PageInfoStrings.promptAllowWhileVisiting, prominent: true, response: .allow)
            }
        case .alert(let message):
            messageLabel.stringValue = "\(Strings.dialogFrom(prompt.origin))\n\(message)"
            addButton(Strings.ok, prominent: true, response: .accept)
        case .confirm(let message):
            messageLabel.stringValue = "\(Strings.dialogFrom(prompt.origin))\n\(message)"
            addButton(Strings.cancel, prominent: false, response: .cancel)
            addButton(Strings.ok, prominent: true, response: .accept)
        case .beforeUnload(let isReload):
            messageLabel.stringValue = "\(isReload ? Strings.beforeUnloadReloadTitle : Strings.beforeUnloadLeaveTitle)\n\(Strings.beforeUnloadMessage)"
            addButton(Strings.cancel, prominent: false, response: .cancel)
            addButton(isReload ? Strings.beforeUnloadReload : Strings.beforeUnloadLeave, prominent: true, response: .accept)
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
        case .openExternalApp(let app, _):
            messageLabel.stringValue = Strings.externalAppPrompt(origin: prompt.origin, app: app)
            alwaysCheck.title = Strings.externalAppAlwaysAllow
            alwaysCheck.state = .off
            // A page with no origin offers no "Always allow" (BrowserExternalApps).
            alwaysCheck.isHidden = prompt.origin.isEmpty
            addButton(Strings.cancel, prominent: false, response: .cancel)
            addButton(Strings.externalAppOpen, prominent: true, response: nil)
        case .savePassword(let username, let update):
            let question = update ? Strings.passwordUpdatePrompt(prompt.origin) : Strings.passwordSavePrompt(prompt.origin)
            messageLabel.stringValue = username.isEmpty ? question : "\(question)\n\(username)"
            // An update is for a saved sign-in: Chromium's update bubble has no Never either.
            if !update { addButton(Strings.passwordNever, prominent: false, response: .deny) }
            addButton(Strings.passwordNotNow, prominent: false, response: .cancel)
            addButton(update ? Strings.passwordUpdate : Strings.passwordSave, prominent: true, response: .accept)
        case .verificationOffer(let offer):
            // The code shows here, in chrome the page cannot read; Fill Code types it, never submits.
            messageLabel.stringValue = offer.code.map { Strings.verificationCodeOffer(site: offer.senderSite, code: $0) }
                ?? Strings.verificationLinkOffer(site: offer.senderSite)
            addButton(Strings.verificationNotNow, prominent: false, response: .cancel)
            if offer.link != nil { addButton(Strings.verificationOpenLink, prominent: offer.code == nil, response: .allowOnce) }
            if offer.code != nil { addButton(Strings.verificationFillCode, prominent: true, response: .accept) }
        }
        contentDidChange()
        if !inputField.isHidden {
            window?.makeFirstResponder(inputField)
        } else if !userField.isHidden {
            window?.makeFirstResponder(userField)
        }
    }

    /// The answer of the prompt's prominent button: the typed text, the
    /// typed user name and password, or Open (always, when checked).
    func submit() {
        guard let prompt else { return }
        if case .credentials = prompt.kind {
            prompt.respond(.credentials(user: userField.stringValue, password: passwordField.stringValue))
        } else if case .openExternalApp = prompt.kind {
            prompt.respond(alwaysCheck.state == .on ? .allow : .allowOnce)
        } else if case .verificationOffer(let offer) = prompt.kind {
            // Return answers the prominent button: Fill Code, or Open Link when there is no code.
            prompt.respond(offer.code != nil ? .accept : .allowOnce)
        } else {
            prompt.respond(.text(inputField.stringValue))
        }
    }

    private func addButton(_ title: String, prominent: Bool, response: BrowserPromptResponse?) {
        let button = PromptResponseButton(title: title, prominent: prominent, action: #selector(respond(_:)), target: self)
        button.response = response
        content.addSubview(button)
        buttons.append(button)
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
