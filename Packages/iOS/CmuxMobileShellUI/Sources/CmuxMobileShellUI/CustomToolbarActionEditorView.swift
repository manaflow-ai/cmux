#if os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminalKit
import UIKit

/// UIKit form for creating or editing a terminal toolbar action.
@MainActor
final class CustomToolbarActionEditorViewController: UITableViewController, UITextFieldDelegate, UITextViewDelegate {
    private enum Section: Int, CaseIterable {
        case label
        case command
    }

    private let existing: CustomToolbarAction?
    private let onSave: (CustomToolbarAction) -> Void

    let titleField = UITextField()
    private let titleFieldCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    let commandCell = CustomToolbarActionCommandCell()
    let runAfterTypingSwitch = UISwitch()
    private let runAfterTypingCell = UITableViewCell(style: .default, reuseIdentifier: nil)

    private(set) lazy var saveButton: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: L10n.string("mobile.common.save", defaultValue: "Save"),
            style: .done,
            target: self,
            action: #selector(saveAction)
        )
        item.accessibilityIdentifier = "CustomActionSaveButton"
        return item
    }()

    init(action: CustomToolbarAction?, onSave: @escaping (CustomToolbarAction) -> Void) {
        existing = action
        self.onSave = onSave
        super.init(style: .insetGrouped)

        let seed = Self.seed(from: action)
        titleField.text = seed.title
        commandCell.textView.text = seed.text
        runAfterTypingSwitch.isOn = seed.runAfterTyping
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = existing == nil
            ? L10n.string("mobile.toolbar.editor.addTitle", defaultValue: "Add Action")
            : L10n.string("mobile.toolbar.editor.editTitle", defaultValue: "Edit Action")
        navigationItem.largeTitleDisplayMode = .never

        let cancel = UIBarButtonItem(
            title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"),
            style: .plain,
            target: self,
            action: #selector(cancelAction)
        )
        cancel.accessibilityIdentifier = "CustomActionCancelButton"
        navigationItem.leftBarButtonItem = cancel
        navigationItem.rightBarButtonItem = saveButton

        titleField.placeholder = L10n.string(
            "mobile.toolbar.editor.titlePlaceholder",
            defaultValue: "Button label"
        )
        titleField.autocorrectionType = .no
        titleField.clearButtonMode = .whileEditing
        titleField.returnKeyType = .next
        titleField.accessibilityIdentifier = "CustomActionTitleField"
        titleField.delegate = self
        titleField.addTarget(self, action: #selector(textDidChange), for: .editingChanged)
        configureTitleFieldCell()

        commandCell.textView.delegate = self
        commandCell.textView.accessibilityIdentifier = "CustomActionCommandField"
        commandCell.placeholderLabel.text = L10n.string(
            "mobile.toolbar.editor.commandPlaceholder",
            defaultValue: "claude --dangerously-skip-permissions"
        )
        commandCell.refreshPlaceholder()

        runAfterTypingSwitch.accessibilityIdentifier = "CustomActionRunToggle"
        configureRunAfterTypingCell()

        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 54
        updateSaveState()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .label:
            1
        case .command:
            2
        case nil:
            0
        }
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch (Section(rawValue: indexPath.section), indexPath.row) {
        case (.label, 0):
            return titleFieldCell
        case (.command, 0):
            return commandCell
        case (.command, 1):
            return runAfterTypingCell
        default:
            return UITableViewCell()
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .label:
            L10n.string("mobile.toolbar.editor.titleHeader", defaultValue: "Label")
        case .command:
            L10n.string("mobile.toolbar.editor.commandHeader", defaultValue: "Sends")
        case nil:
            nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .label:
            L10n.string(
                "mobile.toolbar.editor.titleFooter",
                defaultValue: "Shown on the button in the keyboard toolbar."
            )
        case .command:
            L10n.string(
                "mobile.toolbar.editor.commandFooter",
                defaultValue: "The text typed into the terminal when tapped. Turn on Run after typing to press Return automatically."
            )
        case nil:
            nil
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        commandCell.textView.becomeFirstResponder()
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        commandCell.refreshPlaceholder()
        updateSaveState()
    }

    @objc
    func saveAction() {
        guard let action = makeAction() else { return }
        onSave(action)
        dismiss(animated: true)
    }

    @objc
    private func cancelAction() {
        dismiss(animated: true)
    }

    @objc
    private func textDidChange() {
        updateSaveState()
    }

    private func configureTitleFieldCell() {
        titleFieldCell.selectionStyle = .none
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleFieldCell.contentView.addSubview(titleField)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: titleFieldCell.contentView.layoutMarginsGuide.leadingAnchor),
            titleField.trailingAnchor.constraint(equalTo: titleFieldCell.contentView.layoutMarginsGuide.trailingAnchor),
            titleField.topAnchor.constraint(equalTo: titleFieldCell.contentView.topAnchor, constant: 10),
            titleField.bottomAnchor.constraint(equalTo: titleFieldCell.contentView.bottomAnchor, constant: -10),
            titleField.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
    }

    private func configureRunAfterTypingCell() {
        var content = runAfterTypingCell.defaultContentConfiguration()
        content.text = L10n.string(
            "mobile.toolbar.editor.runAfterTyping",
            defaultValue: "Run after typing"
        )
        runAfterTypingCell.contentConfiguration = content
        runAfterTypingCell.selectionStyle = .none
        runAfterTypingCell.accessoryView = runAfterTypingSwitch
        runAfterTypingCell.accessibilityIdentifier = "CustomActionRunToggle"
    }

    private var trimmedTitle: String {
        (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateSaveState() {
        saveButton.isEnabled = !trimmedTitle.isEmpty && !commandCell.textView.text.isEmpty
    }

    func makeAction() -> CustomToolbarAction? {
        let commandText = commandCell.textView.text ?? ""
        guard !trimmedTitle.isEmpty, !commandText.isEmpty else { return nil }
        let text = runAfterTypingSwitch.isOn ? commandText + "\n" : commandText
        return CustomToolbarAction(
            id: existing?.id ?? UUID(),
            title: trimmedTitle,
            symbolName: nil,
            payload: .text(text)
        )
    }

    static func seed(
        from action: CustomToolbarAction?
    ) -> (title: String, text: String, runAfterTyping: Bool) {
        guard let action, case let .text(stored) = action.payload else {
            return (action?.title ?? "", "", true)
        }
        if stored.hasSuffix("\n") {
            return (action.title, String(stored.dropLast()), true)
        }
        return (action.title, stored, false)
    }
}

@MainActor
final class CustomToolbarActionCommandCell: UITableViewCell {
    let textView = UITextView()
    let placeholderLabel = UILabel()

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        textView.adjustsFontForContentSizeCategory = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.isScrollEnabled = false

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = textView.font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 1

        contentView.addSubview(textView)
        contentView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor, constant: -5),
            textView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor, constant: 5),
            textView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshPlaceholder() {
        placeholderLabel.isHidden = !textView.text.isEmpty
    }
}
#endif
