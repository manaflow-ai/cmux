#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import CmuxMobileSupport
import UIKit

/// Messages' New Message sheet: "New Message" with a glass X, the To: field
/// (tokens, autocomplete, + Add Contact), the service line under it, and the
/// composer. The first send opens (or creates) the conversation.
public final class ConversationComposeViewController: UIViewController {
    public let session: ConversationComposeSession
    /// Called with the opened conversation and the first message to send there.
    public var onOpenConversation: ((ConversationCreation, ConversationComposeMessage) -> Void)?
    /// Called when the person picks + (Add Contact). Without a handler the
    /// sheet lists every contact the directory knows.
    public var onAddContact: (() -> Void)?
    /// The sheet went away (the X, a swipe down, or the host's dismissal), before the host's
    /// dismissal completion runs.
    public var onDismiss: (() -> Void)?
    /// An action row under To: was picked (``ConversationComposeAction``).
    public var onAction: ((ConversationComposeAction) -> Void)?
    /// The conversation the chosen people already have, shown under To: as
    /// Messages and cmux's Mac New Message show it: the host returns its
    /// controller (its own composer then replaces the sheet's, its header
    /// slides under the To: field) or nil for the blank page. Asked again
    /// each time the tokens change; `carrying` is what the sheet's composer
    /// holds, for the conversation's composer to take.
    public var existingConversation: ((_ recipients: [ConversationRecipient], _ carrying: ConversationComposeMessage) -> UIViewController?)?

    let recipientField = ComposeRecipientField()
    private lazy var recipientHeight = recipientField.heightAnchor.constraint(equalToConstant: recipientField.preferredHeight)
    let serviceTitle = UILabel()
    let serviceSubtitle = UILabel()
    /// cmux Home's refusal line under To: (the Mac's `HomeNewMessageView.notice`), in place of Messages' alert.
    let notice = UILabel()
    let suggestionsTable = UITableView(frame: .zero, style: .plain)
    let composer = ConversationComposerView()
    /// Holds the existing conversation under To: (``existingConversation``).
    private let existingContainer = ComposeExistingContainer()
    private(set) var existingController: UIViewController?
    private var existingKey: [String] = []
    private let composerContainer = ComposerHostView()
    private var composerHeight: NSLayoutConstraint?
    /// The list under To: ends at the composer while it shows, at the keyboard while it hides.
    private var listAboveComposer: NSLayoutConstraint?
    private var listAboveKeyboard: NSLayoutConstraint?
    private var listUnderField: NSLayoutConstraint?
    private var listUnderNotice: NSLayoutConstraint?
    /// The docked keyboard's top edge: the composer sits on it.
    private var keyboardDock: MobileKeyboardDock?
    private let keyboardTracker = MobileKeyboardFrameTracker()
    /// The sheet's keyboard tracker: a conversation shown under To:
    /// (``existingConversation``) takes it, since the keyboard rose before that
    /// conversation existed and a new tracker would not know it is up.
    public var keyboard: MobileKeyboardFrameTracker { keyboardTracker }

    public init(directory: any ConversationDirectory) {
        session = ConversationComposeSession(directory: directory)
        if let listing = directory as? any ConversationComposeListing { session.listing = listing }
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "conversation.compose.title", defaultValue: "New Message", bundle: .module)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var pendingDraft: ConversationComposeMessage?

    /// Prefills the message (Forward hands its draft here): the text goes in
    /// the message field, images become attachment cards, and the To: field
    /// keeps focus for picking recipients. Safe to call before presentation.
    public func setDraft(_ message: ConversationComposeMessage) {
        guard isViewLoaded else {
            pendingDraft = message
            return
        }
        composer.text = message.text
        for image in message.images {
            guard let uiImage = UIImage(data: image.data) else { continue }
            composer.addAttachment(ComposerAttachment(image: uiImage, data: image.data, mimeType: image.mimeType))
        }
        recipientField.textField.becomeFirstResponder()
    }

    /// Forward: New Message opens with the selected messages' text, one per
    /// line, and their photos (the local copy, or the loaded image).
    public func setDraft(forwarding draft: ConversationForwardDraft) {
        Task { @MainActor [weak self] in
            var images: [ConversationComposeImage] = []
            for attachment in draft.attachments where attachment.kind == .image {
                if let data = attachment.localData {
                    images.append(ConversationComposeImage(data: data, width: attachment.width, height: attachment.height, mimeType: "image/jpeg"))
                } else if let image = await ConversationImageLoader.shared.image(for: attachment, pixelWidth: 2048),
                          let data = image.jpegData(compressionQuality: 0.9) {
                    images.append(ConversationComposeImage(data: data, width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale), mimeType: "image/jpeg"))
                }
            }
            self?.setDraft(ConversationComposeMessage(text: draft.draftText, images: images))
        }
    }

    /// Wraps the controller in its navigation bar and configures the sheet.
    public func makeSheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = false
        return navigation
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ConversationTheme.background
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        close.accessibilityLabel = String(localized: "conversation.compose.cancel", defaultValue: "Cancel", bundle: .module)
        close.accessibilityIdentifier = "conversation.compose.cancel"
        navigationItem.rightBarButtonItem = close
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: UIColor.label]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance

        for label in [serviceTitle, serviceSubtitle] {
            label.textAlignment = .center
            // Messages draws the service line in the system secondary label
            // (60,60,67 / 235,235,245 at 60%), like the transcript header.
            label.textColor = ConversationTheme.timestampText
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isHidden = true
            view.addSubview(label)
        }
        serviceTitle.font = .systemFont(ofSize: 11, weight: .medium)
        serviceTitle.accessibilityIdentifier = "conversation.compose.service"
        serviceSubtitle.isAccessibilityElement = false
        let lockImage = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold))!
            .withTintColor(ConversationTheme.timestampText, renderingMode: .alwaysOriginal)
        let lock = NSTextAttachment(image: lockImage)
        // Measured: a ~7 x 9 pt lock sitting on the baseline.
        lock.bounds = CGRect(x: 0, y: -0.5, width: 7, height: 9)
        let encrypted = NSMutableAttributedString(attachment: lock)
        encrypted.append(NSAttributedString(
            string: " " + String(localized: "conversation.start.encrypted", defaultValue: "Encrypted", bundle: .module),
            attributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: ConversationTheme.timestampText]
        ))
        serviceSubtitle.attributedText = encrypted

        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.font = .preferredFont(forTextStyle: .footnote)
        notice.adjustsFontForContentSizeCategory = true
        notice.textColor = .systemRed
        notice.numberOfLines = 0
        notice.textAlignment = .center
        notice.isHidden = true
        notice.accessibilityIdentifier = "conversation.compose.notice"
        view.addSubview(notice)

        suggestionsTable.translatesAutoresizingMaskIntoConstraints = false
        suggestionsTable.dataSource = self
        suggestionsTable.delegate = self
        suggestionsTable.register(ComposeSuggestionCell.self, forCellReuseIdentifier: ComposeSuggestionCell.reuseID)
        suggestionsTable.register(ComposeSectionCell.self, forCellReuseIdentifier: ComposeSectionCell.reuseID)
        suggestionsTable.rowHeight = ComposeSuggestionCell.height
        // iOS 27's Messages ends the hairline 20 pt from the trailing edge; iOS 26's runs to it.
        suggestionsTable.separatorInset = UIEdgeInsets(top: 0, left: ComposeSuggestionCell.textLeading, bottom: 0,
                                                       right: ComposeMetrics.iOS27 ? 20 : 0)
        suggestionsTable.keyboardDismissMode = .none
        suggestionsTable.backgroundColor = ConversationTheme.background
        suggestionsTable.isHidden = true
        suggestionsTable.accessibilityIdentifier = "conversation.compose.suggestions"
        // Rows size to the text size: a change redraws them.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.suggestionsTable.reloadData()
        }
        view.addSubview(suggestionsTable)

        existingContainer.translatesAutoresizingMaskIntoConstraints = false
        existingContainer.clipsToBounds = true
        existingContainer.isHidden = true
        existingContainer.accessibilityIdentifier = "conversation.compose.existing"
        // Under the To: field and the list, so neither is ever covered.
        view.insertSubview(existingContainer, at: 0)

        recipientField.translatesAutoresizingMaskIntoConstraints = false
        recipientField.delegate = self
        view.addSubview(recipientField)

        composerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerContainer)
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.delegate = self
        // Messages' compose composer: no placeholder, apps disabled until a conversation exists.
        composer.placeholderText = ""
        composer.plusButton.isEnabled = false
        // The keyboard is up for the whole of New Message: the bar keeps
        // its keyboard side inset (16 pt), as Messages' does.
        composer.keyboardProgress = 1
        composerContainer.addSubview(composer)
        let composerHeight = composer.heightAnchor.constraint(equalToConstant: composer.preferredHeight)
        self.composerHeight = composerHeight

        let keyboard = MobileKeyboardDock(view: view, usesBottomSafeArea: true, keyboard: keyboardTracker)
        keyboardDock = keyboard
        let m = ComposeMetrics.self
        NSLayoutConstraint.activate([
            recipientField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: m.fieldTopGap),
            recipientField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m.fieldInset),
            recipientField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m.fieldInset),
            recipientHeight,
            // Measured: the service line starts 22 pt under the capsule.
            serviceTitle.topAnchor.constraint(equalTo: recipientField.bottomAnchor, constant: 22),
            notice.topAnchor.constraint(equalTo: recipientField.bottomAnchor, constant: 12),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            serviceTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            serviceTitle.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            serviceSubtitle.topAnchor.constraint(equalTo: serviceTitle.bottomAnchor, constant: 1),
            serviceSubtitle.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            serviceSubtitle.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            suggestionsTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestionsTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // From the sheet's top: the transcript scrolls under To: and the title, behind the
            // system's scroll edge effect (the conversation starts below the field).
            existingContainer.topAnchor.constraint(equalTo: view.topAnchor),
            existingContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            existingContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            existingContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Like the conversation's docked composer: the field 16 pt above
            // the keyboard (Messages' New Message, iOS 27.0: 557 over 573).
            composerContainer.bottomAnchor.constraint(equalTo: keyboard.guide.topAnchor, constant: -4 + ConversationKeyboardPinGeometry.dockedDrop),
            composer.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            composer.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor),
            composerHeight,
        ])

        // The list starts under To:, or under the refusal line while it shows (the Mac's
        // `HomeNewMessageView` lays its list under the notice, so the Chiefs never hide it).
        listUnderField = suggestionsTable.topAnchor.constraint(equalTo: recipientField.bottomAnchor, constant: 8)
        listUnderNotice = suggestionsTable.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 8)
        listUnderField?.isActive = true
        listAboveComposer = suggestionsTable.bottomAnchor.constraint(equalTo: composerContainer.topAnchor)
        listAboveKeyboard = suggestionsTable.bottomAnchor.constraint(equalTo: keyboard.guide.topAnchor)
        listAboveComposer?.isActive = true
        session.onChange = { [weak self] change in self?.sessionDidChange(change) }
        sessionDidChange(.recipients)
        // The listing's rows were made before this handler was set: show them now.
        sessionDidChange(.rows)
        if let pendingDraft {
            self.pendingDraft = nil
            setDraft(pendingDraft)
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        recipientField.textField.becomeFirstResponder()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            onDismiss?()
            onDismiss = nil
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        keyboardDock?.refresh()
    }

    private func sessionDidChange(_ change: ConversationComposeSession.Change) {
        switch change {
        case .recipients:
            recipientField.update(draft: session.draft)
            say(nil)
            updateExisting()
            updateServiceLine()
        case .suggestions:
            updateServiceLine()
        case .rows:
            suggestionsTable.reloadData()
            suggestionsTable.isHidden = session.rows.isEmpty
            updateComposerVisibility()
            updateServiceLine()
        case .sending:
            composer.sendButton.isEnabled = !session.isSending
        }
    }

    private func updateServiceLine() {
        let service = session.draft.service
        serviceTitle.text = switch service {
        case .sms: String(localized: "conversation.compose.service.sms", defaultValue: "Text Message • SMS", bundle: .module)
        case .iMessage, nil: "iMessage"
        }
        // cmux Home (a listing) has no service line: its people are not reached over iMessage or SMS.
        let hidden = service == nil || session.listing != nil || !session.rows.isEmpty || existingController != nil || !notice.isHidden
        serviceTitle.isHidden = hidden
        serviceSubtitle.isHidden = hidden
    }

    // MARK: Existing conversation

    /// The tokens changed: show the conversation the chosen people already
    /// have (the host's controller), else the blank page with the sheet's
    /// composer. A red or unresolved token means no one is settled yet: the
    /// blank page. Text being typed in To: changes nothing (the Mac's
    /// `existingConversation` reads the tokens only); the list shows over it.
    private func updateExisting() {
        let draft = session.draft
        let key = draft.canSend ? draft.recipients.map(\.id) : []
        guard key != existingKey else { return }
        existingKey = key
        let carrying = currentMessage()
        let next = key.isEmpty ? nil : existingConversation?(draft.recipients, carrying)
        guard next !== existingController else { return }
        // The leaving conversation's typed text comes back to the blank page's box.
        let returning = (existingController as? any ConversationComposeEmbeddable)?.composeDraftText
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let old = existingController {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        existingController = next
        if let next {
            addChild(next)
            existingContainer.embedded = next
            existingContainer.addSubview(next.view)
            next.didMove(toParent: self)
            attachEdgeEffect(to: next)
            // The conversation's composer takes what was typed (the host gave it `carrying`).
            if !carrying.isEmpty { composer.clearAfterSend() }
        } else {
            existingContainer.embedded = nil
            detachEdgeEffect()
            if !returning.isEmpty, composer.text.isEmpty { composer.text = returning }
        }
        existingContainer.isHidden = next == nil
        updateComposerVisibility()
        existingContainer.setNeedsLayout()
    }

    /// Messages hides the message bar while matches for typed text show (the list runs to the
    /// keyboard) and while a conversation under To: has its own; otherwise the list ends above it.
    private func updateComposerVisibility() {
        let hidden = existingController != nil || (!session.draft.query.isEmpty && !session.rows.isEmpty)
        guard composerContainer.isHidden != hidden || listAboveKeyboard?.isActive != hidden else { return }
        composerContainer.isHidden = hidden
        listAboveComposer?.isActive = !hidden
        listAboveKeyboard?.isActive = hidden
    }

    private var edgeInteraction: UIInteraction?

    /// The To: field and the navigation bar sit over the embedded transcript's top edge: the
    /// native scroll edge effect runs under both (`UIScrollEdgeElementContainerInteraction`,
    /// `setContentScrollView`), and the transcript starts under the field.
    private func attachEdgeEffect(to controller: UIViewController) {
        guard let embeddable = controller as? any ConversationComposeEmbeddable else { return }
        view.layoutIfNeeded()
        let scroll = embeddable.composeEmbed(topInset: recipientField.frame.maxY + ComposeMetrics.existingGap)
        detachEdgeEffect()
        guard let scroll else { return }
        setContentScrollView(scroll, for: .top)
        if #available(iOS 26.0, *) {
            let interaction = UIScrollEdgeElementContainerInteraction()
            interaction.scrollView = scroll
            interaction.edge = .top
            recipientField.addInteraction(interaction)
            edgeInteraction = interaction
        }
    }

    private func detachEdgeEffect() {
        if let edgeInteraction { recipientField.removeInteraction(edgeInteraction) }
        edgeInteraction = nil
        setContentScrollView(nil, for: .top)
    }

    /// Asks the host again for the conversation of the chosen people (its data arrived after the
    /// tokens settled: a Mac Chief whose channel just opened).
    public func reloadExistingConversation() {
        guard existingController == nil else { return }
        existingKey = []
        updateExisting()
    }

    /// The sheet composer's text and images, as the first message.
    private func currentMessage() -> ConversationComposeMessage {
        let images = composer.attachments.filter { $0.file == nil }.map { attachment in
            ConversationComposeImage(
                data: attachment.data,
                width: Int(attachment.image.size.width * attachment.image.scale),
                height: Int(attachment.image.size.height * attachment.image.scale),
                mimeType: attachment.mimeType
            )
        }
        return ConversationComposeMessage(text: composer.text.trimmingCharacters(in: .whitespacesAndNewlines), images: images)
    }

    // MARK: Sending

    private func sendFirstMessage() {
        let message = currentMessage()
        guard !message.isEmpty, !session.isSending else { return }
        if session.draft.recipients.isEmpty && session.draft.query.isEmpty {
            if session.listing != nil {
                say(String(localized: "conversation.compose.needsRecipient", defaultValue: "Add someone in To: first.", bundle: .module))
            }
            recipientField.textField.becomeFirstResponder()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let creation = try await self.session.openConversation()
                self.composer.clearAfterSend()
                self.onOpenConversation?(creation, message)
            } catch {
                self.showSendError(error)
            }
        }
    }

    /// The refusal line under To:, or nil to hide it.
    public func say(_ text: String?) {
        guard notice.text != text || notice.isHidden != (text == nil) else { return }
        notice.text = text
        notice.isHidden = text == nil
        listUnderField?.isActive = text == nil
        listUnderNotice?.isActive = text != nil
        if text != nil { updateServiceLine() }
        view.setNeedsLayout()
    }

    private func showSendError(_ error: any Error) {
        let invalid = (error as? ConversationBackendError)?.code == -32005
        if session.listing != nil {
            // cmux Home, as on the Mac: the reason under To:, which takes the keyboard back.
            let message: String
            if invalid, let red = session.draft.recipients.first(where: { $0.state == .invalid }) {
                message = String(format: String(localized: "conversation.compose.unknownRecipient",
                                                defaultValue: "No one named “%@”. Type their email address to invite them.",
                                                bundle: .module), red.name)
            } else {
                message = (error as? ConversationBackendError)?.message ?? String(describing: error)
            }
            say(message)
            recipientField.textField.becomeFirstResponder()
            return
        }
        let alert = UIAlertController(
            title: invalid
                ? String(localized: "conversation.compose.invalid.title", defaultValue: "Not a Valid Address", bundle: .module)
                : String(localized: "conversation.compose.failed.title", defaultValue: "Could Not Start Conversation", bundle: .module),
            message: invalid
                ? String(localized: "conversation.compose.invalid.message", defaultValue: "Remove the red recipients and try again.", bundle: .module)
                : String(describing: error),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "conversation.compose.ok", defaultValue: "OK", bundle: .module), style: .default))
        present(alert, animated: true)
    }

    // MARK: Add Contact

    private func showAllContacts() {
        let picker = ComposeContactPickerController(directory: session.directory, excluding: session.draft.contactIDs) { [weak self] contact in
            self?.session.add(contact)
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    // MARK: Lab

    /// Drives the sheet headlessly (DEBUG labs): `to <text>`, `return`,
    /// `backspace`, `tap <token index>`, `pick <suggestion index>`,
    /// `body <text>` (focuses the message field), `draft <text>` (Forward prefill), `send`, `add`, `state`.
    public func labCommand(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "to":
            recipientField.textField.text = arg
            recipientField.textField.sendActions(for: .editingChanged)
        case "return":
            session.commitText()
        case "backspace":
            recipientField.textField.deleteBackward()
            recipientField.textField.sendActions(for: .editingChanged)
        case "tap":
            guard let index = Int(arg), index < session.draft.recipients.count else { return "error no token" }
            session.select(session.draft.recipients[index].id)
        case "pick":
            // The index counts the list's pickable rows (headers skipped), as a tap would reach them.
            let pickable = session.rows.filter(\.isSelectable)
            guard let index = Int(arg), index < pickable.count else { return "error no suggestion" }
            activate(pickable[index])
        case "body":
            composer.textView.becomeFirstResponder()
            composer.text = arg
        case "draft":
            setDraft(ConversationComposeMessage(text: arg))
        case "send":
            sendFirstMessage()
        case "add":
            recipientFieldDidTapAdd(recipientField)
        case "state":
            break
        default:
            return "error unknown"
        }
        let draft = session.draft
        let tokens = draft.recipients.map { r in "\(r.name)[\(r.state)]\(r.id == draft.selectedID ? "*" : "")" }.joined(separator: ",")
        let rows = session.rows.map { row -> String in
            switch row {
            case let .header(title): "#\(title)"
            case let .contact(contact): contact.name
            case let .action(action): "+\(action.id)"
            }
        }.joined(separator: ",")
        return "tokens=\(tokens) text=\(draft.text) suggestions=\(rows) service=\(draft.service?.rawValue ?? "-") existing=\(existingController != nil)"
    }
}

extension ConversationComposeViewController: ComposeRecipientFieldDelegate {
    func recipientFieldDidChangeText(_ field: ComposeRecipientField, text: String) {
        session.setText(text)
    }

    func recipientFieldDidReturn(_ field: ComposeRecipientField) {
        session.commitText()
    }

    func recipientFieldDidDeleteBackward(_ field: ComposeRecipientField) -> Bool {
        session.backspace()
    }

    func recipientField(_ field: ComposeRecipientField, didTapToken id: String) {
        // An empty id deselects (a tap on the text area, or focus leaving the field).
        session.select(id.isEmpty ? nil : id)
        if !id.isEmpty { field.textField.becomeFirstResponder() }
    }

    func recipientFieldDidTapAdd(_ field: ComposeRecipientField) {
        if let onAddContact {
            onAddContact()
        } else {
            showAllContacts()
        }
    }

    func recipientFieldDidChangeHeight(_ field: ComposeRecipientField) {
        recipientHeight.constant = field.preferredHeight
        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
        // The transcript under To: starts below the field's new bottom.
        if let embeddable = existingController as? any ConversationComposeEmbeddable {
            _ = embeddable.composeEmbed(topInset: recipientField.frame.maxY + ComposeMetrics.existingGap)
        }
    }
}

extension ConversationComposeViewController: ConversationComposerViewDelegate {
    func composerDidChangeText(_ composer: ConversationComposerView) {}

    func composerDidChangeHeight(_ composer: ConversationComposerView) {
        composerHeight?.constant = composer.preferredHeight
        view.layoutIfNeeded()
    }

    func composerDidTapSend(_ composer: ConversationComposerView) {
        sendFirstMessage()
    }

    func composerDidTapPlus(_ composer: ConversationComposerView) {}

    /// The New Message sheet has no Send with Effect (it sends the first message plain).
    func composerDidLongPressSend(_ composer: ConversationComposerView) {}
}

extension ConversationComposeViewController: UITableViewDataSource, UITableViewDelegate {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        session.rows.count
    }

    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard indexPath.row < session.rows.count else { return ComposeSuggestionCell.height }
        let traits = tableView.traitCollection
        switch session.rows[indexPath.row] {
        case .header: return ComposeSectionCell.height(traits)
        case .contact: return ComposeSuggestionCell.height(traits)
        case let .action(action): return ComposeSuggestionCell.height(action.title, width: tableView.bounds.width, traits: traits)
        }
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch session.rows[indexPath.row] {
        case let .header(title):
            let cell = tableView.dequeueReusableCell(withIdentifier: ComposeSectionCell.reuseID, for: indexPath)
            (cell as? ComposeSectionCell)?.configure(title)
            return cell
        case let .contact(contact):
            let cell = tableView.dequeueReusableCell(withIdentifier: ComposeSuggestionCell.reuseID, for: indexPath)
            (cell as? ComposeSuggestionCell)?.configure(contact, query: session.draft.query)
            return cell
        case let .action(action):
            let cell = tableView.dequeueReusableCell(withIdentifier: ComposeSuggestionCell.reuseID, for: indexPath)
            (cell as? ComposeSuggestionCell)?.configure(action)
            return cell
        }
    }

    public func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        indexPath.row < session.rows.count && session.rows[indexPath.row].isSelectable
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard indexPath.row < session.rows.count else { return }
        activate(session.rows[indexPath.row])
    }

    /// A row picked: a contact becomes a token, an action runs.
    func activate(_ row: ConversationComposeRow) {
        switch row {
        case .header: break
        case let .contact(contact): session.add(contact)
        case let .action(action): onAction?(action)
        }
    }
}

/// An autocomplete row: avatar, the name with the typed prefix in bold, and
/// the address that will be used under it.
final class ComposeSuggestionCell: UITableViewCell {
    static let reuseID = "compose.suggestion"
    /// The list under To:: iOS 26 measured 60 pt rows and a 40 pt avatar at x 16; iOS 27 is
    /// 55.3 pt with 36 pt at x 20 (both put the name at x 68). The Contacts picker keeps 60/40.
    static var height: CGFloat { ComposeMetrics.iOS27 ? 55.33 : 60 }
    static let listedHeight: CGFloat = 60
    static let avatarSize: CGFloat = 40
    static let textLeading: CGFloat = 16 + avatarSize + 12
    /// This row is in the list under To: (not the Contacts picker).
    private var suggestion = true
    private let avatar = ConversationAvatarView()
    /// An action row's leading circle (New Chief, Invite) in place of the avatar.
    private let symbolCircle = UIView()
    private let symbol = UIImageView()
    private let name = UILabel()
    private let detail = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.addSubview(avatar)
        symbolCircle.backgroundColor = .secondarySystemFill
        symbolCircle.layer.cornerRadius = Self.avatarSize / 2
        symbolCircle.isHidden = true
        symbol.contentMode = .center
        symbol.tintColor = .systemBlue
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        symbolCircle.addSubview(symbol)
        contentView.addSubview(symbolCircle)
        name.font = .systemFont(ofSize: 17)
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = .secondaryLabel
        detail.adjustsFontForContentSizeCategory = false
        contentView.addSubview(name)
        contentView.addSubview(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Text size: 1 at the default size, larger with Dynamic Type (Messages' rows grow with it).
    static func scale(_ traits: UITraitCollection) -> CGFloat {
        max(1, UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits) / 17)
    }

    /// The measured height at the default size (55.33 on iOS 27), scaled up with larger text.
    static func height(_ traits: UITraitCollection) -> CGFloat {
        let s = scale(traits)
        return s == 1 ? height : (height * s).rounded(.up)
    }

    /// An action row's height: one line, or two for a long title ("Invite … to <team>").
    static func height(_ title: String, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let s = scale(traits)
        let text = NSAttributedString(string: title, attributes: [.font: UIFont.systemFont(ofSize: 17 * s)])
        let lines = text.boundingRect(with: CGSize(width: max(1, width - textLeading - 16), height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin], context: nil).height
        return max(height(traits), (min(lines, 2 * 22 * s) + 20 * s).rounded(.up))
    }

    private var s: CGFloat { Self.scale(traitCollection) }

    func configure(_ contact: ConversationContact, query: String) {
        suggestion = true
        avatar.isHidden = false
        symbolCircle.isHidden = true
        name.numberOfLines = 1
        detail.font = .systemFont(ofSize: 15 * s)
        avatar.configure(initials: contact.initials, colorHex: contact.colorHex)
        let text = NSMutableAttributedString(string: contact.name, attributes: [.font: UIFont.systemFont(ofSize: 17 * s), .foregroundColor: UIColor.label])
        // Bold the matched word prefix, as Messages does.
        let words = contact.name.split(separator: " ")
        var offset = 0
        for word in words {
            if !query.isEmpty, word.lowercased().hasPrefix(query.lowercased()) {
                text.addAttribute(.font, value: UIFont.systemFont(ofSize: 17 * s, weight: .semibold), range: NSRange(location: offset, length: query.count))
                break
            }
            offset += word.count + 1
        }
        name.attributedText = text
        let handle = contact.handles.first
        if let line = contact.detail, !contact.tintsWithService {
            // cmux Home's line ("Chief · Main · Cloud", "Team"): where the person is, not an address.
            detail.text = line
            detail.textColor = .secondaryLabel
        } else if let line = contact.detail {
            // A typed address: Messages tints the name and its line with the service color.
            detail.text = line
            detail.textColor = contact.service == .iMessage ? .systemBlue : .systemGreen
            if ComposeMetrics.iOS27 {
                text.addAttribute(.foregroundColor, value: detail.textColor ?? .label, range: NSRange(location: 0, length: text.length))
                name.attributedText = text
            }
        } else {
            detail.text = handle.map { ComposeMetrics.iOS27 || $0.label.isEmpty ? $0.value : "\($0.label) \($0.value)" }
            detail.textColor = contact.service == .iMessage ? .systemBlue : .systemGreen
            if ComposeMetrics.iOS27 {
                // iOS 27 tints the name with its address (bold prefix included).
                text.addAttribute(.foregroundColor, value: detail.textColor ?? .label, range: NSRange(location: 0, length: text.length))
                name.attributedText = text
            }
        }
        accessibilityLabel = contact.name
        accessibilityValue = contact.detail ?? handle?.value
        accessibilityTraits = .button
        accessibilityIdentifier = "conversation.compose.suggestion.\(contact.id)"
        setNeedsLayout()
    }

    /// An action row: the symbol in a gray circle, its title in the tint.
    func configure(_ action: ConversationComposeAction) {
        suggestion = true
        avatar.isHidden = true
        symbolCircle.isHidden = false
        symbol.image = UIImage(systemName: action.systemImage)
        name.numberOfLines = 2
        name.attributedText = NSAttributedString(string: action.title, attributes: [.font: UIFont.systemFont(ofSize: 17 * s), .foregroundColor: UIColor.systemBlue])
        detail.text = nil
        accessibilityLabel = action.title
        accessibilityValue = nil
        accessibilityTraits = .button
        accessibilityIdentifier = "conversation.compose.action.\(action.id)"
        setNeedsLayout()
    }

    /// The Contacts list: no address line, the last name bold, the
    /// monogram on Messages' gray gradient.
    func configureListed(_ contact: ConversationContact) {
        suggestion = false
        avatar.isHidden = false
        symbolCircle.isHidden = true
        name.numberOfLines = 1
        avatar.configure(initials: contact.initials, colorHex: nil)
        let text = NSMutableAttributedString(string: contact.name, attributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.label])
        let key = ComposeContactPickerController.sortKey(contact.name)
        if key != contact.name.uppercased(), let range = contact.name.range(of: key, options: .caseInsensitive) {
            text.addAttribute(.font, value: UIFont.systemFont(ofSize: 17, weight: .semibold), range: NSRange(range, in: contact.name))
        }
        name.attributedText = text
        detail.text = nil
        accessibilityLabel = contact.name
        accessibilityIdentifier = "conversation.compose.contact.\(contact.id)"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let compact = suggestion && ComposeMetrics.iOS27
        let size: CGFloat = compact ? 36 : Self.avatarSize
        let leading = CGRect(x: compact ? 20 : 16, y: (bounds.height - size) / 2, width: size, height: size)
        avatar.frame = leading
        symbolCircle.frame = leading
        symbolCircle.layer.cornerRadius = size / 2
        // The symbol keeps clear of the circle: a wide one ("person.2.badge.plus") scales down
        // into the inner box; a small one ("plus") stays at its own size, centered.
        let box = symbolCircle.bounds.insetBy(dx: size * 0.24, dy: size * 0.24)
        let natural = symbol.image?.size ?? .zero
        symbol.contentMode = natural.width > box.width || natural.height > box.height ? .scaleAspectFit : .center
        symbol.frame = box
        let x = Self.textLeading
        let hasDetail = !(detail.text ?? "").isEmpty
        let s = suggestion ? s : 1
        let width = bounds.width - x - 16
        if name.numberOfLines == 1 {
            name.frame = CGRect(x: x, y: hasDetail ? (compact ? 8.3 : 9) * s : (bounds.height - 22 * s) / 2, width: width, height: 22 * s)
        } else {
            let fit = name.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            name.frame = CGRect(x: x, y: (bounds.height - fit) / 2, width: width, height: fit)
        }
        detail.frame = CGRect(x: x, y: (compact ? 28.7 : 31) * s, width: width, height: 19 * s)
    }
}

/// A section title in the list under To: ("Chiefs", "Team"): the list's
/// plain-style header, secondary text on the sheet's background; never picked.
final class ComposeSectionCell: UITableViewCell {
    static let reuseID = "compose.section"
    static let height: CGFloat = 32
    static func height(_ traits: UITraitCollection) -> CGFloat { (height * ComposeSuggestionCell.scale(traits)).rounded(.up) }
    private let title = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .secondaryLabel
        contentView.addSubview(title)
        // A header row draws no separator of its own.
        separatorInset = UIEdgeInsets(top: 0, left: 10_000, bottom: 0, right: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String) {
        title.font = .systemFont(ofSize: 15 * ComposeSuggestionCell.scale(traitCollection), weight: .semibold)
        title.text = text
        accessibilityLabel = text
        accessibilityTraits = .header
        accessibilityIdentifier = "conversation.compose.section.\(text)"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = ComposeSuggestionCell.scale(traitCollection)
        title.frame = CGRect(x: 16, y: bounds.height - 24 * s, width: bounds.width - 32, height: 20 * s)
    }
}

/// Holds the existing conversation under To:. Its controller's own header
/// would sit at the top of this view; the view is laid out that much higher,
/// so the header slides under the To: field and the transcript starts right
/// under it (the Mac's `HomeNewMessageClip`).
final class ComposeExistingContainer: UIView {
    weak var embedded: UIViewController?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let embedded else { return }
        // Twice at most: the header's height is known once the controller has laid out at this width.
        for _ in 0..<2 {
            let header = (embedded as? any ConversationComposeEmbeddable)?.composeHeaderHeight ?? 0
            let frame = CGRect(x: 0, y: -header, width: bounds.width, height: bounds.height + header)
            guard embedded.view.frame != frame else { return }
            embedded.view.frame = frame
            embedded.view.layoutIfNeeded()
        }
    }
}

/// A controller New Message shows under To: tells how tall its own header is,
/// so the sheet can hide that header under the field.
@MainActor
public protocol ConversationComposeEmbeddable: AnyObject {
    var composeHeaderHeight: CGFloat { get }
    /// Starts the transcript at `topInset` (under the sheet's To: field) and returns its scroll
    /// view for the top edge effect.
    func composeEmbed(topInset: CGFloat) -> UIScrollView?
    /// What its own message box holds: it comes back to the sheet's when the conversation leaves
    /// (the recipients changed), as the Mac's New Message keeps the typed text.
    var composeDraftText: String { get }
}

extension ConversationViewController: ConversationComposeEmbeddable {
    public var composeHeaderHeight: CGFloat { showsHeader ? headerMaxY : 0 }
    public func composeEmbed(topInset: CGFloat) -> UIScrollView? {
        embeddedTopInset = topInset
        return transcriptScrollView
    }
    public var composeDraftText: String { composer.text }
}

/// + (Add Contact): a stacked "Contacts" sheet, sectioned by last name
/// with an A to Z index (measured: 38 pt headers, 60 pt rows, 40 pt avatar
/// at 16 pt, names at 68 pt with the last name bold).
final class ComposeContactPickerController: UITableViewController {
    private let directory: any ConversationDirectory
    private let excluding: [String]
    private let onPick: (ConversationContact) -> Void
    private var sections: [(title: String, contacts: [ConversationContact])] = []

    init(directory: any ConversationDirectory, excluding: [String], onPick: @escaping (ConversationContact) -> Void) {
        self.directory = directory
        self.excluding = excluding
        self.onPick = onPick
        super.init(style: .plain)
        title = String(localized: "conversation.compose.contacts", defaultValue: "Contacts", bundle: .module)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func sortKey(_ name: String) -> String {
        let words = name.split(separator: " ").filter { !$0.hasSuffix(".") || $0.count > 3 }
        return (words.count > 1 ? String(words[1]) : name).uppercased()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let back = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        back.accessibilityLabel = String(localized: "conversation.compose.back", defaultValue: "Back", bundle: .module)
        navigationItem.leftBarButtonItem = back
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.register(ComposeSuggestionCell.self, forCellReuseIdentifier: ComposeSuggestionCell.reuseID)
        tableView.rowHeight = ComposeSuggestionCell.listedHeight
        tableView.sectionHeaderHeight = 38
        tableView.sectionHeaderTopPadding = 0
        tableView.separatorInset = UIEdgeInsets(top: 0, left: ComposeSuggestionCell.textLeading, bottom: 0, right: 0)
        tableView.accessibilityIdentifier = "conversation.compose.contacts"
        let excluding = excluding
        Task { [weak self, directory] in
            let all = (try? await directory.searchContacts("", limit: 500, excluding: excluding)) ?? []
            guard let self else { return }
            let sorted = all.sorted { Self.sortKey($0.name) < Self.sortKey($1.name) }
            var sections: [(title: String, contacts: [ConversationContact])] = []
            for contact in sorted {
                let letter = String(Self.sortKey(contact.name).prefix(1))
                let title = letter.rangeOfCharacter(from: .letters) == nil ? "#" : letter
                if sections.last?.title == title { sections[sections.count - 1].contacts.append(contact) } else { sections.append((title, [contact])) }
            }
            self.sections = sections
            self.tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].contacts.count }

    /// Measured: the letter at x 18, a full-width hairline (16 pt insets) under it.
    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 38))
        let label = UILabel()
        label.text = sections[section].title
        label.font = .systemFont(ofSize: 17)
        label.textColor = .secondaryLabel
        label.frame = CGRect(x: 18, y: 6, width: 40, height: 22)
        header.addSubview(label)
        let line = UIView()
        line.backgroundColor = .separator
        line.frame = CGRect(x: 16, y: 37.5, width: tableView.bounds.width - 32, height: 0.5)
        line.autoresizingMask = [.flexibleWidth]
        header.addSubview(line)
        return header
    }

    override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ#".map(String.init)
    }

    override func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        sections.lastIndex { $0.title <= title } ?? 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ComposeSuggestionCell.reuseID, for: indexPath) as! ComposeSuggestionCell
        cell.configureListed(sections[indexPath.section].contacts[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let contact = sections[indexPath.section].contacts[indexPath.row]
        dismiss(animated: true) { [onPick] in onPick(contact) }
    }
}

extension ConversationComposeViewController {
    /// DEBUG labs on the conversation simulator: the first send shows the
    /// opened conversation in `navigation` (replacing the one shown, since
    /// the lab has no conversation list), sends the message, and dismisses.
    public static func presentForSimulator(
        over navigation: UINavigationController,
        backend: ConversationSimBackend
    ) -> ConversationComposeViewController {
        let compose = ConversationComposeViewController(directory: backend)
        compose.onOpenConversation = { [weak navigation] creation, message in
            guard let navigation else { return }
            let store = ConversationStore(backend: ConversationSimBackend(endpoint: backend.endpoint(forConversation: creation.info.id)))
            let options = ConversationPresentationOptions(
                serviceTitle: creation.service == .sms
                    ? String(localized: "conversation.compose.service.sms", defaultValue: "Text Message • SMS", bundle: .module)
                    : "iMessage"
            )
            let controller = ConversationViewController(store: store, options: options)
            // Keep the host's Back behavior (the lab opens New Message again).
            controller.onBack = (navigation.viewControllers.first as? ConversationViewController)?.onBack
            navigation.setViewControllers([controller], animated: false)
            store.sendWhenConnected(message)
            navigation.dismiss(animated: true)
        }
        navigation.present(compose.makeSheet(), animated: true)
        return compose
    }
}
#endif
