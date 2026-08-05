#if os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminal
import CmuxMobileTerminalKit
import UIKit

/// UIKit editor for the terminal input-accessory shortcut bar.
///
/// The controller observes the same configuration notification as the live
/// terminal toolbar, so changes made from another presentation are reflected
/// immediately without an external observation bridge.
@MainActor
final class TerminalShortcutsSettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case shortcuts
        case addAction
        case reset
    }

    private let configuration: TerminalAccessoryConfiguration
    private let scope: TerminalShortcutsSettingsScope

    init(
        scope: TerminalShortcutsSettingsScope = .terminal,
        configuration: TerminalAccessoryConfiguration = .shared
    ) {
        self.scope = scope
        self.configuration = configuration
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = scope.navigationTitle
        navigationItem.largeTitleDisplayMode = .never

        editButtonItem.accessibilityIdentifier = "TerminalShortcutsEditButton"
        navigationItem.leftBarButtonItem = editButtonItem

        let done = UIBarButtonItem(
            title: L10n.string("mobile.common.done", defaultValue: "Done"),
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
        done.accessibilityIdentifier = "TerminalShortcutsDoneButton"
        navigationItem.rightBarButtonItem = done

        tableView.register(TerminalShortcutToggleCell.self, forCellReuseIdentifier: TerminalShortcutToggleCell.reuseIdentifier)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 50

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configurationDidChange),
            name: TerminalAccessoryConfiguration.didChangeNotification,
            object: configuration
        )
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .shortcuts:
            displayedItems.count
        case .addAction, .reset:
            1
        case nil:
            0
        }
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .shortcuts:
            guard indexPath.row < displayedItems.count,
                  let cell = tableView.dequeueReusableCell(
                      withIdentifier: TerminalShortcutToggleCell.reuseIdentifier,
                      for: indexPath
                  ) as? TerminalShortcutToggleCell else {
                return UITableViewCell()
            }
            let item = displayedItems[indexPath.row]
            cell.configure(
                item: item,
                isEnabled: configuration.isEnabled(item.id)
            ) { [weak self] isEnabled in
                self?.configuration.setEnabled(item.id, isEnabled)
            }
            cell.showsReorderControl = true
            return cell

        case .addAction:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("mobile.shortcuts.addAction", defaultValue: "Add Custom Action")
            content.image = UIImage(systemName: "plus")
            content.imageProperties.tintColor = .tintColor
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "TerminalShortcutsAddActionButton"
            cell.accessoryType = .disclosureIndicator
            return cell

        case .reset:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("mobile.shortcuts.reset", defaultValue: "Reset to Defaults")
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "TerminalShortcutsResetButton"
            return cell

        case nil:
            return UITableViewCell()
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard Section(rawValue: section) == .shortcuts else { return nil }
        return L10n.string("mobile.shortcuts.header", defaultValue: "Shortcut Buttons")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section) == .shortcuts else { return nil }
        return scope.footer
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .shortcuts:
            guard indexPath.row < displayedItems.count,
                  let action = displayedItems[indexPath.row].customAction else { return }
            presentEditor(for: action)
        case .addAction:
            presentEditor(for: nil)
        case .reset:
            configuration.resetToDefaults()
        case nil:
            break
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .shortcuts
    }

    override func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        guard Section(rawValue: indexPath.section) == .shortcuts,
              indexPath.row < displayedItems.count,
              displayedItems[indexPath.row].isCustom else { return .none }
        return .delete
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete,
              indexPath.row < displayedItems.count,
              let action = displayedItems[indexPath.row].customAction else { return }
        configuration.removeCustomAction(id: action.id)
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .shortcuts,
              indexPath.row < displayedItems.count,
              let action = displayedItems[indexPath.row].customAction else { return nil }

        let delete = UIContextualAction(
            style: .destructive,
            title: L10n.string("mobile.common.delete", defaultValue: "Delete")
        ) { [weak self] _, _, completion in
            self?.configuration.removeCustomAction(id: action.id)
            completion(true)
        }
        delete.image = UIImage(systemName: "trash")

        let edit = UIContextualAction(
            style: .normal,
            title: L10n.string("mobile.common.edit", defaultValue: "Edit")
        ) { [weak self] _, _, completion in
            self?.presentEditor(for: action)
            completion(true)
        }
        edit.backgroundColor = .systemBlue
        edit.image = UIImage(systemName: "pencil")

        let actions = UISwipeActionsConfiguration(actions: [delete, edit])
        actions.performsFirstActionWithFullSwipe = false
        return actions
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .shortcuts
    }

    override func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        guard sourceIndexPath.section == Section.shortcuts.rawValue,
              destinationIndexPath.section == Section.shortcuts.rawValue else {
            tableView.reloadData()
            return
        }
        reorderVisibleItem(from: sourceIndexPath.row, to: destinationIndexPath.row)
    }

    @objc
    private func doneTapped() {
        dismiss(animated: true)
    }

    @objc
    private func configurationDidChange() {
        tableView.reloadData()
    }

    private var displayedItems: [ResolvedToolbarItem] {
        configuration.displayItems.filter(scope.includes)
    }

    private func reorderVisibleItem(from sourceIndex: Int, to destinationIndex: Int) {
        var visibleIDs = displayedItems.map(\.id)
        guard visibleIDs.indices.contains(sourceIndex),
              destinationIndex >= 0,
              destinationIndex < visibleIDs.count else { return }

        let moved = visibleIDs.remove(at: sourceIndex)
        visibleIDs.insert(moved, at: destinationIndex)

        let visibleSet = Set(visibleIDs)
        var iterator = visibleIDs.makeIterator()
        let fullOrder = configuration.displayOrder.map { id in
            guard visibleSet.contains(id) else { return id }
            return iterator.next() ?? id
        }
        configuration.reorderItems(fullOrder)
    }

    private func presentEditor(for action: CustomToolbarAction?) {
        let editor = CustomToolbarActionEditorViewController(action: action) { [weak self] edited in
            guard let self else { return }
            if action == nil {
                configuration.addCustomAction(edited)
            } else {
                configuration.updateCustomAction(edited)
            }
        }
        present(UINavigationController(rootViewController: editor), animated: true)
    }
}

@MainActor
final class TerminalShortcutToggleCell: UITableViewCell {
    static let reuseIdentifier = "TerminalShortcutToggleCell"

    let toggle = UISwitch()
    private var onChange: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        accessoryView = toggle
        toggle.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        item: ResolvedToolbarItem,
        isEnabled: Bool,
        onChange: @escaping (Bool) -> Void
    ) {
        var content = defaultContentConfiguration()
        content.text = item.settingsDisplayName
        if item.isCustom {
            content.image = UIImage(systemName: "character.cursor.ibeam")
            content.imageProperties.tintColor = .secondaryLabel
        }
        contentConfiguration = content

        let identifier = "TerminalShortcutToggle.\(item.id.storageKey)"
        accessibilityIdentifier = identifier
        toggle.accessibilityIdentifier = identifier
        toggle.accessibilityLabel = item.settingsDisplayName
        toggle.setOn(isEnabled, animated: false)
        self.onChange = onChange
    }

    @objc
    private func valueChanged() {
        onChange?(toggle.isOn)
    }
}
#endif
