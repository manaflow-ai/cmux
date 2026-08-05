#if os(iOS)
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import UIKit

/// Native task composer backed by the existing idempotent shell submission API.
@MainActor
final class MobileTaskComposerViewController: UITableViewController, UITextFieldDelegate, UITextViewDelegate {
    private enum Row: Int, CaseIterable {
        case template
        case prompt
        case computer
        case directory
        case workspaceName
        case launch
    }

    private let store: CMUXMobileShellStore
    private let sessionGeneration: Int
    private var templates: [MobileTaskTemplate]
    private var machines: [MobilePairedMac]
    private var selectedTemplateID: MobileTaskTemplate.ID?
    private var selectedPairingID: String?
    private var operationID: UUID
    private var didEditDirectory: Bool
    private var isSubmitting = false
    private var shouldPersistDraft = true
    private var submitTask: Task<Void, Never>?

    private let promptView = UITextView()
    private let directoryField = UITextField()
    private let workspaceNameField = UITextField()

    init(store: CMUXMobileShellStore) {
        self.store = store
        sessionGeneration = store.currentSessionGeneration
        let availableTemplates = store.taskTemplateStore?.listTemplates() ?? []
        let availableMachines = store.displayPairedMacs
        templates = availableTemplates
        machines = availableMachines
        let draft = store.taskTemplateStore?.composerDraft()
        let validTemplateID = draft?.templateID.flatMap { id in
            availableTemplates.contains(where: { $0.id == id }) ? id : nil
        }
        selectedTemplateID = validTemplateID
            ?? store.taskTemplateStore?.lastTemplateID().flatMap { id in
                availableTemplates.contains(where: { $0.id == id }) ? id : nil
            }
            ?? availableTemplates.first?.id
        let preferredMacID = draft?.macDeviceID
            ?? store.taskTemplateStore?.lastMacDeviceID()
            ?? store.connectedMacDeviceID
        let selectedMachine = availableMachines.first {
            $0.macDeviceID == preferredMacID && $0.instanceTag == draft?.macInstanceTag
        } ?? availableMachines.first {
            $0.macDeviceID == preferredMacID && $0.isActive
        } ?? availableMachines.first { $0.macDeviceID == preferredMacID }
            ?? availableMachines.first
        selectedPairingID = selectedMachine?.id
        operationID = draft?.operationID ?? UUID()
        didEditDirectory = draft?.didEditDirectory ?? false
        super.init(style: .insetGrouped)
        title = L10n.string("mobile.taskComposer.title", defaultValue: "New Task")
        promptView.text = draft?.prompt ?? ""
        workspaceNameField.text = draft?.workspaceName ?? ""
        if let draft, draft.didEditDirectory {
            directoryField.text = draft.directory
        } else {
            directoryField.text = suggestedDirectory(
                template: selectedTemplate,
                machine: selectedMachine
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit { submitTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 58
        tableView.accessibilityIdentifier = "MobileTaskComposer"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("mobile.taskComposer.editTemplates", defaultValue: "Templates"),
            primaryAction: UIAction { [weak self] _ in self?.showTemplates() }
        )
        configureFields()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard shouldPersistDraft else { return }
        store.persistTaskComposerDraft(currentDraft, ifSessionGeneration: sessionGeneration)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? Row.allCases.count - 1 : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0
            ? L10n.string("mobile.taskComposer.request", defaultValue: "Task")
            : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = indexPath.section == 0 ? Row(rawValue: indexPath.row)! : .launch
        switch row {
        case .template:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = L10n.string("mobile.taskComposer.template", defaultValue: "Template")
            cell.detailTextLabel?.text = selectedTemplate?.name
                ?? L10n.string("mobile.taskComposer.template.none", defaultValue: "None")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "MobileTaskComposerTemplate"
            return cell
        case .prompt:
            return textViewCell(
                promptView,
                identifier: "MobileTaskComposerPrompt",
                minimumHeight: 150
            )
        case .computer:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = L10n.string("mobile.taskComposer.computer", defaultValue: "Computer")
            cell.detailTextLabel?.text = selectedMachine?.resolvedName
                ?? L10n.string("mobile.taskComposer.computer.none", defaultValue: "No Computer")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "MobileTaskComposerComputer"
            return cell
        case .directory:
            return textFieldCell(directoryField, identifier: "MobileTaskComposerDirectory")
        case .workspaceName:
            return textFieldCell(workspaceNameField, identifier: "MobileTaskComposerWorkspaceName")
        case .launch:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = isSubmitting
                ? L10n.string("mobile.taskComposer.launching", defaultValue: "Starting…")
                : L10n.string("mobile.taskComposer.launch", defaultValue: "Start Task")
            cell.textLabel?.textAlignment = .center
            cell.textLabel?.textColor = canSubmit ? view.tintColor : .tertiaryLabel
            cell.selectionStyle = canSubmit ? .default : .none
            cell.accessibilityIdentifier = "MobileTaskComposerLaunch"
            if isSubmitting {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
            }
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = indexPath.section == 0 ? Row(rawValue: indexPath.row)! : .launch
        switch row {
        case .template: chooseTemplate(source: tableView.cellForRow(at: indexPath))
        case .computer: chooseComputer(source: tableView.cellForRow(at: indexPath))
        case .launch: submit()
        default: break
        }
    }

    private func configureFields() {
        promptView.font = .preferredFont(forTextStyle: .body)
        promptView.adjustsFontForContentSizeCategory = true
        promptView.delegate = self
        promptView.keyboardDismissMode = .interactive
        promptView.accessibilityIdentifier = "MobileTaskComposerPrompt"

        directoryField.placeholder = L10n.string("mobile.taskComposer.directory", defaultValue: "Working Directory")
        directoryField.autocapitalizationType = .none
        directoryField.autocorrectionType = .no
        directoryField.clearButtonMode = .whileEditing
        directoryField.delegate = self
        directoryField.addAction(UIAction { [weak self] _ in self?.didEditDirectory = true }, for: .editingChanged)

        workspaceNameField.placeholder = L10n.string("mobile.taskComposer.workspaceName", defaultValue: "Workspace Name (optional)")
        workspaceNameField.clearButtonMode = .whileEditing
        workspaceNameField.delegate = self
    }

    private func textViewCell(
        _ textView: UITextView,
        identifier: String,
        minimumHeight: CGFloat
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = identifier
        textView.translatesAutoresizingMaskIntoConstraints = false
        if textView.superview !== cell.contentView {
            textView.removeFromSuperview()
            cell.contentView.addSubview(textView)
        }
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight),
        ])
        return cell
    }

    private func textFieldCell(_ field: UITextField, identifier: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = identifier
        field.translatesAutoresizingMaskIntoConstraints = false
        field.removeFromSuperview()
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
        return cell
    }

    private var selectedTemplate: MobileTaskTemplate? {
        selectedTemplateID.flatMap { id in templates.first { $0.id == id } }
    }

    private var selectedMachine: MobilePairedMac? {
        selectedPairingID.flatMap { id in machines.first { $0.id == id } }
    }

    private var canSubmit: Bool {
        !isSubmitting && selectedTemplate != nil && selectedMachine != nil
    }

    private func chooseTemplate(source: UIView?) {
        let alert = UIAlertController(
            title: L10n.string("mobile.taskComposer.template", defaultValue: "Template"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for template in templates {
            alert.addAction(UIAlertAction(title: template.name, style: .default) { [weak self] _ in
                guard let self else { return }
                selectedTemplateID = template.id
                if !didEditDirectory {
                    directoryField.text = suggestedDirectory(template: template, machine: selectedMachine)
                }
                tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"), style: .cancel))
        configurePopover(alert, source: source)
        present(alert, animated: true)
    }

    private func chooseComputer(source: UIView?) {
        let alert = UIAlertController(
            title: L10n.string("mobile.taskComposer.computer", defaultValue: "Computer"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for machine in machines {
            alert.addAction(UIAlertAction(title: machine.resolvedName, style: .default) { [weak self] _ in
                guard let self else { return }
                selectedPairingID = machine.id
                if !didEditDirectory {
                    directoryField.text = suggestedDirectory(template: selectedTemplate, machine: machine)
                }
                tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"), style: .cancel))
        configurePopover(alert, source: source)
        present(alert, animated: true)
    }

    private func configurePopover(_ controller: UIViewController, source: UIView?) {
        controller.popoverPresentationController?.sourceView = source ?? view
        controller.popoverPresentationController?.sourceRect = source?.bounds
            ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    }

    private func suggestedDirectory(
        template: MobileTaskTemplate?,
        machine: MobilePairedMac?
    ) -> String {
        if let directory = template?.defaultDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            return directory
        }
        if let macID = machine?.macDeviceID,
           let directory = store.taskTemplateStore?.lastDirectory(macDeviceID: macID),
           !directory.isEmpty {
            return directory
        }
        return "~"
    }

    private var currentDraft: MobileTaskComposerDraft {
        MobileTaskComposerDraft(
            prompt: promptView.text,
            templateID: selectedTemplateID,
            macDeviceID: selectedMachine?.macDeviceID,
            macInstanceTag: selectedMachine?.instanceTag,
            directory: directoryField.text ?? "",
            didEditDirectory: didEditDirectory,
            workspaceName: workspaceNameField.text,
            operationID: operationID
        )
    }

    private func submit() {
        guard canSubmit, let template = selectedTemplate, let machine = selectedMachine else { return }
        let snapshot = MobileTaskSubmissionSnapshot(
            template: template,
            prompt: promptView.text,
            macDeviceID: machine.macDeviceID,
            macInstanceTag: machine.instanceTag,
            directory: directoryField.text ?? "",
            workspaceName: workspaceNameField.text ?? "",
            didEditDirectory: didEditDirectory,
            operationID: operationID
        )
        let spec = MobileWorkspaceCreateSpec(
            title: snapshot.workspaceTitle,
            workingDirectory: snapshot.trimmedDirectory.isEmpty ? nil : snapshot.trimmedDirectory,
            initialCommand: snapshot.composition.initialCommand,
            initialEnv: snapshot.composition.initialEnv.isEmpty ? nil : snapshot.composition.initialEnv,
            operationID: snapshot.operationID
        )
        isSubmitting = true
        tableView.reloadData()
        submitTask?.cancel()
        submitTask = Task { [weak self] in
            guard let self else { return }
            let result = await store.submitTaskComposer(
                macDeviceID: snapshot.macDeviceID,
                instanceTag: snapshot.macInstanceTag,
                spec: spec
            )
            guard !Task.isCancelled else { return }
            switch result {
            case .success:
                shouldPersistDraft = false
                store.completeTaskComposerSubmission(snapshot, ifSessionGeneration: sessionGeneration)
                dismiss(animated: true)
            case .failure:
                isSubmitting = false
                tableView.reloadData()
                presentSubmissionError()
            }
        }
    }

    private func presentSubmissionError() {
        let alert = UIAlertController(
            title: L10n.string("mobile.taskComposer.failure.title", defaultValue: "Task Could Not Start"),
            message: L10n.string("mobile.taskComposer.failure.message", defaultValue: "Check the selected computer and connection, then try again."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func showTemplates() {
        let controller = MobileTaskTemplateListViewController(store: store) { [weak self] in
            guard let self else { return }
            templates = store.taskTemplateStore?.listTemplates() ?? []
            if !templates.contains(where: { $0.id == selectedTemplateID }) {
                selectedTemplateID = templates.first?.id
            }
            tableView.reloadData()
        }
        navigationController?.pushViewController(controller, animated: true)
    }
}

@MainActor
private final class MobileTaskTemplateListViewController: UITableViewController {
    private let store: CMUXMobileShellStore
    private let changed: @MainActor () -> Void
    private var templates: [MobileTaskTemplate] = []

    init(store: CMUXMobileShellStore, changed: @escaping @MainActor () -> Void) {
        self.store = store
        self.changed = changed
        super.init(style: .insetGrouped)
        title = L10n.string("mobile.taskComposer.templates", defaultValue: "Task Templates")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in self?.edit(nil) }
        )
        reload()
    }

    private func reload() {
        templates = store.taskTemplateStore?.listTemplates() ?? []
        if isViewLoaded { tableView.reloadData() }
        changed()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { templates.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let template = templates[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = template.name
        cell.detailTextLabel?.text = template.isPlainShell
            ? L10n.string("mobile.taskComposer.template.shell", defaultValue: "Plain Shell")
            : template.command
        cell.imageView?.image = UIImage(systemName: template.icon) ?? UIImage(systemName: "terminal")
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        edit(templates[indexPath.row])
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let template = templates[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: L10n.string("mobile.common.delete", defaultValue: "Delete")) { [weak self] _, _, completion in
            self?.store.taskTemplateStore?.deleteTemplate(id: template.id)
            self?.reload()
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func edit(_ template: MobileTaskTemplate?) {
        let editor = MobileTaskTemplateEditorViewController(template: template) { [weak self] value in
            guard let self else { return }
            if template == nil {
                store.taskTemplateStore?.addTemplate(value)
            } else {
                store.taskTemplateStore?.updateTemplate(value)
            }
            reload()
        }
        navigationController?.pushViewController(editor, animated: true)
    }
}

@MainActor
private final class MobileTaskTemplateEditorViewController: UITableViewController, UITextFieldDelegate, UITextViewDelegate {
    private let templateID: UUID
    private let saveTemplate: @MainActor (MobileTaskTemplate) -> Void
    private let nameField = UITextField()
    private let iconField = UITextField()
    private let directoryField = UITextField()
    private let commandView = UITextView()

    init(template: MobileTaskTemplate?, save: @escaping @MainActor (MobileTaskTemplate) -> Void) {
        templateID = template?.id ?? UUID()
        saveTemplate = save
        super.init(style: .insetGrouped)
        title = template == nil
            ? L10n.string("mobile.taskComposer.template.add", defaultValue: "Add Template")
            : L10n.string("mobile.taskComposer.template.edit", defaultValue: "Edit Template")
        nameField.text = template?.name
        iconField.text = template?.icon ?? "terminal"
        directoryField.text = template?.defaultDirectory
        commandView.text = template?.command
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("mobile.common.save", defaultValue: "Save"),
            primaryAction: UIAction { [weak self] _ in self?.save() }
        )
        configure(nameField, placeholder: L10n.string("mobile.taskComposer.template.name", defaultValue: "Name"))
        configure(iconField, placeholder: L10n.string("mobile.taskComposer.template.icon", defaultValue: "SF Symbol or Emoji"))
        configure(directoryField, placeholder: L10n.string("mobile.taskComposer.directory", defaultValue: "Working Directory"))
        commandView.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        commandView.autocapitalizationType = .none
        commandView.autocorrectionType = .no
        commandView.delegate = self
    }

    private func configure(_ field: UITextField, placeholder: String) {
        field.placeholder = placeholder
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        field.delegate = self
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 3 : 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? L10n.string("mobile.taskComposer.template.command", defaultValue: "Command") : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let view: UIView
        if indexPath.section == 0 {
            view = [nameField, iconField, directoryField][indexPath.row]
        } else {
            commandView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            view = commandView
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.removeFromSuperview()
        cell.contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
        ])
        return cell
    }

    private func save() {
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let directory = (directoryField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        saveTemplate(MobileTaskTemplate(
            id: templateID,
            name: name,
            icon: (iconField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            command: commandView.text,
            defaultDirectory: directory.isEmpty ? nil : directory
        ))
        navigationController?.popViewController(animated: true)
    }
}
#endif
