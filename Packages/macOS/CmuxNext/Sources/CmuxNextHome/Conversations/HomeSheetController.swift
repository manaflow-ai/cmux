public import AppKit
public import CmuxHomeCore
import CmuxNextDesign

/// The frame of the Home page's sheets (New Message, Invite, New Chief): a
/// title, the sheet's own content, a status line that says why an action
/// did not finish, and Cancel plus a default button. `run` disables the
/// buttons while the action runs; an opened conversation or a sent invite
/// closes the sheet and reaches `onFinish`.
public class HomeSheetController: NSViewController {
    /// The sheet finished with a conversation to show (nil: nothing to show).
    public var onFinish: (ConversationID?) -> Void = { _ in }

    let titleLabel = NSTextField(labelWithString: "")
    let stack = NSStackView()
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let cancelButton = NSButton(title: HomeConversationStrings.cancel, target: nil, action: nil)
    let primaryButton = NSButton(title: "", target: nil, action: nil)
    let buttons = NSStackView()
    private(set) var isRunning = false
    // task-owner: the sheet's one running action; cancelled when the sheet closes
    private var work: Task<Void, Never>?

    init(title: String, primary: String) {
        super.init(nibName: nil, bundle: nil)
        titleLabel.stringValue = title
        primaryButton.title = primary
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        stack.edgeInsets = NSEdgeInsets(top: Metrics.space6, left: Metrics.space6, bottom: Metrics.space6, right: Metrics.space6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Typography.title
        titleLabel.setAccessibilityRole(.staticText)
        stack.addArrangedSubview(titleLabel)
        addContent(to: stack)
        statusLabel.isHidden = true
        statusLabel.font = Typography.caption
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("cmux.home.sheet.status")
        stack.addArrangedSubview(statusLabel)
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        primaryButton.target = self
        primaryButton.action = #selector(primary(_:))
        primaryButton.keyEquivalent = "\r"
        primaryButton.setAccessibilityIdentifier("cmux.home.sheet.primary")
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.space3
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(cancelButton)
        buttons.addArrangedSubview(primaryButton)
        stack.addArrangedSubview(buttons)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 420),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Metrics.space6),
        ])
        view = root
        refreshPrimary()
    }

    /// Subclasses add their fields between the title and the status line.
    func addContent(to stack: NSStackView) {}

    /// Whether the default button may run now (subclasses check their fields).
    var canSubmit: Bool { true }

    /// The default button's action; subclasses call `run`.
    func submit() {}

    func refreshPrimary() {
        primaryButton.isEnabled = canSubmit && !isRunning
    }

    /// Runs `action`: an opened conversation or a sent invite closes the
    /// sheet; anything else stays and says why.
    func run(_ action: @escaping @MainActor () async -> HomeComposeOutcome) {
        guard !isRunning else { return }
        isRunning = true
        show(nil)
        refreshPrimary()
        work = Task { [weak self] in
            let outcome = await action()
            guard let self, !Task.isCancelled else { return }
            isRunning = false
            refreshPrimary()
            finish(outcome)
        }
    }

    /// Handles a finished action's outcome (subclasses add offers, such as
    /// Invite by Email after `notReachable`).
    func finish(_ outcome: HomeComposeOutcome) {
        switch outcome {
        case .opened(let id): close(showing: id)
        case .invited(let id): close(showing: id)
        default: show(HomeConversationStrings.outcome(outcome))
        }
    }

    /// The status line; nil hides it. VoiceOver hears it.
    func show(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
        if let text {
            NSAccessibility.post(element: statusLabel, notification: .announcementRequested, userInfo: [.announcement: text])
        }
    }

    func close(showing id: ConversationID?) {
        work?.cancel()
        if let presenting = presentingViewController {
            presenting.dismiss(self)
        } else if let window = view.window, let parent = window.sheetParent {
            parent.endSheet(window)
        }
        onFinish(id)
    }

    @objc func cancel(_ sender: Any?) { close(showing: nil) }
    @objc func primary(_ sender: Any?) { if canSubmit, !isRunning { submit() } }

    /// A text field with a placeholder, as wide as the sheet.
    static func field(placeholder: String, identifier: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityIdentifier(identifier)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 420 - 2 * Metrics.space6).isActive = true
        return field
    }
}
