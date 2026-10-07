#if canImport(UIKit)
import CmuxConversationCore
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

    let recipientField = ComposeRecipientField()
    private lazy var recipientHeight = recipientField.heightAnchor.constraint(equalToConstant: recipientField.preferredHeight)
    let serviceTitle = UILabel()
    let serviceSubtitle = UILabel()
    let suggestionsTable = UITableView(frame: .zero, style: .plain)
    let composer = ConversationComposerView()
    private let composerContainer = UIView()
    private var composerHeight: NSLayoutConstraint?

    public init(directory: any ConversationDirectory) {
        session = ConversationComposeSession(directory: directory)
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
            label.textColor = ConversationTheme.secondaryText
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isHidden = true
            view.addSubview(label)
        }
        serviceTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        serviceTitle.accessibilityIdentifier = "conversation.compose.service"
        serviceSubtitle.isAccessibilityElement = false
        let lockImage = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold))!
            .withTintColor(ConversationTheme.secondaryText, renderingMode: .alwaysOriginal)
        let lock = NSTextAttachment(image: lockImage)
        // Measured: a ~7 x 9 pt lock sitting on the baseline.
        lock.bounds = CGRect(x: 0, y: -0.5, width: 7, height: 9)
        let encrypted = NSMutableAttributedString(attachment: lock)
        encrypted.append(NSAttributedString(
            string: " " + String(localized: "conversation.start.encrypted", defaultValue: "Encrypted", bundle: .module),
            attributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: ConversationTheme.secondaryText]
        ))
        serviceSubtitle.attributedText = encrypted

        suggestionsTable.translatesAutoresizingMaskIntoConstraints = false
        suggestionsTable.dataSource = self
        suggestionsTable.delegate = self
        suggestionsTable.register(ComposeSuggestionCell.self, forCellReuseIdentifier: ComposeSuggestionCell.reuseID)
        suggestionsTable.rowHeight = ComposeSuggestionCell.height
        suggestionsTable.separatorInset = UIEdgeInsets(top: 0, left: ComposeSuggestionCell.textLeading, bottom: 0, right: 0)
        suggestionsTable.keyboardDismissMode = .none
        suggestionsTable.backgroundColor = ConversationTheme.background
        suggestionsTable.isHidden = true
        suggestionsTable.accessibilityIdentifier = "conversation.compose.suggestions"
        view.addSubview(suggestionsTable)

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
        composerContainer.addSubview(composer)
        let composerHeight = composer.heightAnchor.constraint(equalToConstant: composer.preferredHeight)
        self.composerHeight = composerHeight

        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        let m = ComposeMetrics.self
        NSLayoutConstraint.activate([
            recipientField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: m.fieldTopGap),
            recipientField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m.fieldInset),
            recipientField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m.fieldInset),
            recipientHeight,
            // Measured: the service line starts 22 pt under the capsule.
            serviceTitle.topAnchor.constraint(equalTo: recipientField.bottomAnchor, constant: 22),
            serviceTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            serviceTitle.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            serviceSubtitle.topAnchor.constraint(equalTo: serviceTitle.bottomAnchor, constant: 1),
            serviceSubtitle.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            serviceSubtitle.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            suggestionsTable.topAnchor.constraint(equalTo: recipientField.bottomAnchor, constant: 8),
            suggestionsTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestionsTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            suggestionsTable.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            composerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -4),
            composer.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            composer.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor),
            composerHeight,
        ])

        session.onChange = { [weak self] change in self?.sessionDidChange(change) }
        sessionDidChange(.recipients)
        if let pendingDraft {
            self.pendingDraft = nil
            setDraft(pendingDraft)
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        recipientField.textField.becomeFirstResponder()
    }

    private func sessionDidChange(_ change: ConversationComposeSession.Change) {
        switch change {
        case .recipients:
            recipientField.update(draft: session.draft)
            updateServiceLine()
        case .suggestions:
            suggestionsTable.reloadData()
            suggestionsTable.isHidden = session.suggestions.isEmpty
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
        let hidden = service == nil || !session.suggestions.isEmpty
        serviceTitle.isHidden = hidden
        serviceSubtitle.isHidden = hidden
    }

    // MARK: Sending

    private func sendFirstMessage() {
        let images = composer.attachments.map { attachment in
            ConversationComposeImage(
                data: attachment.data,
                width: Int(attachment.image.size.width * attachment.image.scale),
                height: Int(attachment.image.size.height * attachment.image.scale),
                mimeType: attachment.mimeType
            )
        }
        let message = ConversationComposeMessage(text: composer.text.trimmingCharacters(in: .whitespacesAndNewlines), images: images)
        guard !message.isEmpty, !session.isSending else { return }
        if session.draft.recipients.isEmpty && session.draft.query.isEmpty {
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

    private func showSendError(_ error: any Error) {
        let invalid = (error as? ConversationBackendError)?.code == -32005
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
            guard let index = Int(arg), index < session.suggestions.count else { return "error no suggestion" }
            session.add(session.suggestions[index])
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
        return "tokens=\(tokens) text=\(draft.text) suggestions=\(session.suggestions.map(\.name).joined(separator: ",")) service=\(draft.service?.rawValue ?? "-")"
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
        session.suggestions.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ComposeSuggestionCell.reuseID, for: indexPath) as! ComposeSuggestionCell
        cell.configure(session.suggestions[indexPath.row], query: session.draft.query)
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard indexPath.row < session.suggestions.count else { return }
        session.add(session.suggestions[indexPath.row])
    }
}

/// An autocomplete row: avatar, the name with the typed prefix in bold, and
/// the address that will be used under it.
final class ComposeSuggestionCell: UITableViewCell {
    static let reuseID = "compose.suggestion"
    static let height: CGFloat = 60
    static let avatarSize: CGFloat = 40
    static let textLeading: CGFloat = 16 + avatarSize + 12
    private let avatar = ConversationAvatarView()
    private let name = UILabel()
    private let detail = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.addSubview(avatar)
        name.font = .systemFont(ofSize: 17)
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = .secondaryLabel
        contentView.addSubview(name)
        contentView.addSubview(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ contact: ConversationContact, query: String) {
        avatar.configure(initials: contact.initials, colorHex: contact.colorHex)
        let text = NSMutableAttributedString(string: contact.name, attributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.label])
        // Bold the matched word prefix, as Messages does.
        let words = contact.name.split(separator: " ")
        var offset = 0
        for word in words {
            if !query.isEmpty, word.lowercased().hasPrefix(query.lowercased()) {
                text.addAttribute(.font, value: UIFont.systemFont(ofSize: 17, weight: .semibold), range: NSRange(location: offset, length: query.count))
                break
            }
            offset += word.count + 1
        }
        name.attributedText = text
        let handle = contact.handles.first
        detail.text = handle.map { "\($0.label) \($0.value)" }
        detail.textColor = contact.service == .iMessage ? .systemBlue : .systemGreen
        accessibilityLabel = contact.name
        accessibilityValue = handle?.value
        accessibilityIdentifier = "conversation.compose.suggestion.\(contact.id)"
    }

    /// The Contacts list: no address line, the last name bold, the
    /// monogram on Messages' gray gradient.
    func configureListed(_ contact: ConversationContact) {
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
        let size = Self.avatarSize
        avatar.frame = CGRect(x: 16, y: (bounds.height - size) / 2, width: size, height: size)
        let x = Self.textLeading
        let hasDetail = !(detail.text ?? "").isEmpty
        name.frame = CGRect(x: x, y: hasDetail ? 9 : (bounds.height - 22) / 2, width: bounds.width - x - 16, height: 22)
        detail.frame = CGRect(x: x, y: 31, width: bounds.width - x - 16, height: 19)
    }
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
        tableView.rowHeight = ComposeSuggestionCell.height
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
