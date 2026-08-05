#if os(iOS)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileToast
import Foundation
import Observation
import UIKit

/// Native settings surface backed directly by the app-root stores.
@MainActor
final class MobileSettingsViewController: UITableViewController {
    private enum Row: Hashable {
        case account
        case deleteAccount
        case signOut
        case team(String)
        case computers
        case addComputer
        case introduction
        case setupHelp
        case connectionMethod
        case scanTailscale
        case iroh
        case altScreenNotice
        case terminalFolderTap
        case terminalShortcuts
        case haptics
        case taskComposer
        case filesChip
        case toasts
        case showMissingFiles
        case wrapTitles
        case previewLines
        case scrollback
        case notifications
        case telemetry
        case privacyPolicy
        case terms
        case support
        case version
    }

    private struct Section {
        let title: String?
        let footer: String?
        let rows: [Row]
    }

    private static let telemetryKey = "sendAnonymousTelemetry"
    private let coordinator: MobileRootCoordinator
    private var sections: [Section] = []
    private var notificationTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?

    init(coordinator: MobileRootCoordinator) {
        self.coordinator = coordinator
        super.init(style: .insetGrouped)
        title = L10n.string("mobile.workspaces.settings", defaultValue: "Settings")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        notificationTask?.cancel()
        accountTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "MobileSettingsView"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "MobileSettingsDone"
        rebuildSections()
    }

    private func rebuildSections() {
        let auth = coordinator.auth
        var result: [Section] = [
            Section(
                title: L10n.string("mobile.settings.account", defaultValue: "Account"),
                footer: L10n.string(
                    "mobile.settings.accountFooter",
                    defaultValue: "This device must be signed in to the same cmux account as the computer you pair with."
                ),
                rows: [.account, .deleteAccount, .signOut]
            ),
        ]
        if auth.availableTeams.count > 1 {
            result.append(Section(
                title: L10n.string("mobile.settings.team", defaultValue: "Team"),
                footer: L10n.string(
                    "mobile.settings.teamFooter",
                    defaultValue: "Switches which Stack team's computers and devices this app shows."
                ),
                rows: auth.availableTeams.map { .team($0.id) }
            ))
        }
        result.append(Section(
            title: L10n.string("mobile.settings.connection", defaultValue: "Connection"),
            footer: nil,
            rows: [.computers, .addComputer, .connectionMethod]
                + (coordinator.connectionMethodStore.method == .tailscale ? [.scanTailscale] : [])
                + [.setupHelp, .introduction]
        ))
        if coordinator.irohSettingsController != nil {
            result.append(Section(
                title: L10n.string("mobile.settings.networking", defaultValue: "Networking"),
                footer: nil,
                rows: [.iroh]
            ))
        }
        result.append(contentsOf: [
            Section(
                title: L10n.string("mobile.settings.terminal", defaultValue: "Terminal"),
                footer: nil,
                rows: [.altScreenNotice, .terminalFolderTap, .terminalShortcuts]
            ),
            Section(
                title: L10n.string("mobile.settings.haptics", defaultValue: "Haptics"),
                footer: L10n.string(
                    "mobile.settings.hapticFeedbackFooter",
                    defaultValue: "When off, cmux does not vibrate for actions, confirmations, warnings, or errors."
                ),
                rows: [.haptics]
            ),
            Section(
                title: L10n.string("mobile.settings.betaFeatures", defaultValue: "Beta Features"),
                footer: nil,
                rows: [.taskComposer, .filesChip, .toasts]
            ),
            Section(
                title: L10n.string("mobile.settings.display", defaultValue: "Display"),
                footer: nil,
                rows: [.showMissingFiles, .wrapTitles, .previewLines, .scrollback]
            ),
            Section(
                title: L10n.string("mobile.settings.notifications", defaultValue: "Push Alerts"),
                footer: nil,
                rows: [.notifications]
            ),
            Section(
                title: L10n.string("mobile.settings.privacy", defaultValue: "Privacy"),
                footer: Self.telemetryFooter,
                rows: [.telemetry]
            ),
            Section(
                title: L10n.string("mobile.settings.legalSupport", defaultValue: "Legal & Support"),
                footer: nil,
                rows: [.privacyPolicy, .terms, .support]
            ),
            Section(
                title: L10n.string("mobile.settings.about", defaultValue: "About"),
                footer: nil,
                rows: [.version]
            ),
        ])
        sections = result
        if isViewLoaded { tableView.reloadData() }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.accessoryType = .none
        cell.selectionStyle = .default
        switch row {
        case .account:
            cell.textLabel?.text = accountDisplayName
            cell.detailTextLabel?.text = accountEmail
            cell.imageView?.image = UIImage(systemName: "person.crop.circle")
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "MobileSettingsAccountRow"
        case .deleteAccount:
            configureDestructive(
                cell,
                title: L10n.string("mobile.settings.deleteAccount", defaultValue: "Delete Account"),
                symbol: "trash",
                identifier: "MobileSettingsDeleteAccount"
            )
        case .signOut:
            configureDestructive(
                cell,
                title: L10n.string("mobile.signOut", defaultValue: "Sign Out"),
                symbol: "rectangle.portrait.and.arrow.right",
                identifier: "MobileSettingsSignOut"
            )
        case .team(let id):
            let team = coordinator.auth.availableTeams.first { $0.id == id }
            cell.textLabel?.text = team?.displayName ?? id
            cell.accessoryType = coordinator.auth.resolvedTeamID == id ? .checkmark : .none
            cell.accessibilityIdentifier = "MobileSettingsTeam-\(id)"
        case .computers:
            configure(cell, title: L10n.string("mobile.settings.computers", defaultValue: "Computers"), symbol: "desktopcomputer", identifier: "MobileSettingsComputers")
            cell.detailTextLabel?.text = "\(coordinator.store.displayPairedMacs.count)"
            cell.accessoryType = .disclosureIndicator
        case .addComputer:
            configure(cell, title: L10n.string("mobile.addDevice.title", defaultValue: "Add Computer"), symbol: "plus", identifier: "MobileSettingsAddComputer")
        case .introduction:
            configure(cell, title: L10n.string("mobile.settings.viewIntroductionAgain", defaultValue: "View Introduction Again"), symbol: "sparkles", identifier: "MobileSettingsHowPairingWorks")
        case .setupHelp:
            configure(cell, title: L10n.string("mobile.settings.setUpYourMac", defaultValue: "Set Up Computer"), symbol: "macbook.and.iphone", identifier: "MobileSettingsSetUpYourMac")
        case .connectionMethod:
            configure(cell, title: L10n.string("mobile.settings.connectionMethod", defaultValue: "Connection Method"), symbol: "point.3.connected.trianglepath.dotted", identifier: "MobileSettingsConnectionMethod")
            cell.detailTextLabel?.text = coordinator.connectionMethodStore.method == .automatic
                ? L10n.string("mobile.settings.connectionMethod.automatic", defaultValue: "Auto-Connect")
                : L10n.string("mobile.settings.connectionMethod.tailscale", defaultValue: "Tailscale")
            cell.accessoryType = .disclosureIndicator
        case .scanTailscale:
            configure(cell, title: L10n.string("mobile.settings.connectionMethod.scanCode", defaultValue: "Scan Pairing Code"), symbol: "qrcode.viewfinder", identifier: "MobileSettingsTailscaleScanButton")
        case .iroh:
            configure(cell, title: L10n.string("mobile.settings.iroh", defaultValue: "Iroh and Relays"), symbol: "network", identifier: "MobileSettingsIroh")
            cell.accessoryType = .disclosureIndicator
        case .altScreenNotice:
            configureSwitch(cell, title: L10n.string("mobile.settings.altScreenNotice", defaultValue: "Full-Screen Sizing Notice"), identifier: "MobileSettingsAltScreenNoticeToggle", isOn: coordinator.displaySettings.showAltScreenNotice) { [weak self] value in self?.coordinator.displaySettings.showAltScreenNotice = value }
        case .terminalFolderTap:
            configureSwitch(cell, title: L10n.string("mobile.settings.terminalFolderTap", defaultValue: "Open Folders on Tap"), identifier: "MobileSettingsTerminalFolderTapToggle", isOn: coordinator.displaySettings.terminalFolderTapEnabled) { [weak self] value in self?.coordinator.displaySettings.terminalFolderTapEnabled = value }
        case .terminalShortcuts:
            configure(cell, title: L10n.string("mobile.workspaces.terminalShortcuts", defaultValue: "Terminal Shortcuts"), symbol: "keyboard", identifier: "MobileSettingsTerminalShortcuts")
            cell.accessoryType = .disclosureIndicator
        case .haptics:
            configureSwitch(cell, title: L10n.string("mobile.settings.hapticFeedback", defaultValue: "Haptic Feedback"), identifier: "MobileSettingsHapticFeedbackToggle", isOn: coordinator.displaySettings.hapticFeedbackEnabled) { [weak self] value in self?.coordinator.displaySettings.hapticFeedbackEnabled = value }
        case .taskComposer:
            configureSwitch(cell, title: L10n.string("mobile.settings.taskComposer", defaultValue: "New Task Composer"), identifier: "MobileSettingsTaskComposer", isOn: coordinator.displaySettings.taskComposerEnabled) { [weak self] value in self?.coordinator.displaySettings.taskComposerEnabled = value }
        case .filesChip:
            configureSwitch(cell, title: L10n.string("mobile.settings.terminalFilesChip", defaultValue: "Terminal Files Chip"), identifier: "MobileSettingsTerminalFilesChip", isOn: coordinator.displaySettings.terminalFilesChipEnabled) { [weak self] value in self?.coordinator.displaySettings.terminalFilesChipEnabled = value }
        case .toasts:
            configureSwitch(cell, title: L10n.string("mobile.settings.beta.toasts", defaultValue: "Toasts"), identifier: "MobileSettingsToastsEnabled", isOn: coordinator.toastCenter.isEnabled) { [weak self] value in self?.coordinator.toastCenter.isEnabled = value }
        case .showMissingFiles:
            configureSwitch(cell, title: L10n.string("mobile.settings.showMissingFiles", defaultValue: "Show missing files"), identifier: "MobileSettingsShowMissingFiles", isOn: coordinator.displaySettings.showMissingFiles) { [weak self] value in self?.coordinator.displaySettings.showMissingFiles = value }
        case .wrapTitles:
            configureSwitch(cell, title: L10n.string("mobile.settings.wrapTitles", defaultValue: "Wrap Workspace Titles"), identifier: "MobileSettingsWrapTitles", isOn: coordinator.displaySettings.wrapWorkspaceTitles) { [weak self] value in self?.coordinator.displaySettings.wrapWorkspaceTitles = value }
        case .previewLines:
            configure(cell, title: L10n.string("mobile.settings.previewLines", defaultValue: "Preview Lines"), symbol: "text.alignleft", identifier: "MobileSettingsPreviewLines")
            cell.detailTextLabel?.text = "\(coordinator.displaySettings.workspacePreviewLineCount)"
            cell.accessoryType = .disclosureIndicator
        case .scrollback:
            configure(cell, title: L10n.string("mobile.settings.terminalScrollback", defaultValue: "Terminal Scrollback"), symbol: "text.line.last.and.arrowtriangle.forward", identifier: "MobileSettingsTerminalScrollback")
            cell.detailTextLabel?.text = coordinator.displaySettings.terminalScrollbackRows.formatted()
            cell.accessoryType = .disclosureIndicator
        case .notifications:
            configure(cell, title: coordinator.pushCoordinator.isEnabled ? L10n.string("mobile.notifications.disable", defaultValue: "Turn Off Push Alerts") : L10n.string("mobile.notifications.enable", defaultValue: "Notify Me When Agents Need Me"), symbol: coordinator.pushCoordinator.isEnabled ? "bell.slash" : "bell", identifier: "MobileSettingsNotifications")
        case .telemetry:
            configureSwitch(cell, title: Self.telemetryTitle, identifier: "MobileSettingsTelemetryToggle", isOn: UserDefaults.standard.bool(forKey: Self.telemetryKey)) { value in UserDefaults.standard.set(value, forKey: Self.telemetryKey) }
        case .privacyPolicy:
            configure(cell, title: L10n.string("mobile.settings.privacyPolicy", defaultValue: "Privacy Policy"), symbol: "hand.raised", identifier: "MobileSettingsPrivacyPolicy")
        case .terms:
            configure(cell, title: L10n.string("mobile.settings.termsOfService", defaultValue: "Terms of Service"), symbol: "doc.text", identifier: "MobileSettingsTermsOfService")
        case .support:
            configure(cell, title: L10n.string("mobile.settings.support", defaultValue: "Support"), symbol: "envelope", identifier: "MobileSettingsSupport")
        case .version:
            configure(cell, title: L10n.string("mobile.settings.version", defaultValue: "Version"), symbol: "info.circle", identifier: "MobileSettingsVersionRow")
            cell.detailTextLabel?.text = AppVersionInfo.current().displayString
            cell.selectionStyle = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .deleteAccount: confirmDeleteAccount()
        case .signOut:
            dismiss(animated: true) { [weak coordinator] in coordinator?.signOut() }
        case .team(let id):
            coordinator.auth.selectedTeamID = id
            coordinator.currentTeamDidChange()
            rebuildSections()
        case .computers:
            navigationController?.pushViewController(
                MobileComputersViewController(store: coordinator.store),
                animated: true
            )
        case .addComputer:
            dismiss(animated: true) { [weak coordinator] in coordinator?.presentAddComputer() }
        case .introduction:
            present(UINavigationController(rootViewController: MobileIntroductionViewController()), animated: true)
        case .setupHelp:
            navigationController?.pushViewController(MobileSetupHelpViewController(), animated: true)
        case .connectionMethod: chooseConnectionMethod()
        case .scanTailscale:
            dismiss(animated: true) { [weak coordinator] in
                coordinator?.presentPairingScanner(entry: .settingsReplay)
            }
        case .iroh:
            if let controller = coordinator.irohSettingsController {
                navigationController?.pushViewController(
                    MobileIrohSettingsViewController(controller: controller),
                    animated: true
                )
            }
        case .terminalShortcuts:
            navigationController?.pushViewController(TerminalShortcutsSettingsViewController(), animated: true)
        case .previewLines:
            chooseValue(
                title: L10n.string("mobile.settings.previewLines", defaultValue: "Preview Lines"),
                values: [1, 2],
                label: { "\($0)" }
            ) { [weak self] value in self?.coordinator.displaySettings.workspacePreviewLineCount = value }
        case .scrollback:
            chooseValue(
                title: L10n.string("mobile.settings.terminalScrollback", defaultValue: "Terminal Scrollback"),
                values: [1_000, 4_000, 10_000, 20_000],
                label: { $0.formatted() }
            ) { [weak self] value in self?.coordinator.displaySettings.terminalScrollbackRows = value }
        case .notifications: toggleNotifications()
        case .privacyPolicy: open(URL(string: "https://cmux.com/privacy-policy")!)
        case .terms: open(URL(string: "https://cmux.com/terms-of-service")!)
        case .support: open(Self.supportURL)
        default: break
        }
    }

    private func configure(_ cell: UITableViewCell, title: String, symbol: String, identifier: String) {
        cell.textLabel?.text = title
        cell.imageView?.image = UIImage(systemName: symbol)
        cell.accessibilityIdentifier = identifier
    }

    private func configureDestructive(_ cell: UITableViewCell, title: String, symbol: String, identifier: String) {
        configure(cell, title: title, symbol: symbol, identifier: identifier)
        cell.textLabel?.textColor = .systemRed
        cell.imageView?.tintColor = .systemRed
    }

    private func configureSwitch(
        _ cell: UITableViewCell,
        title: String,
        identifier: String,
        isOn: Bool,
        changed: @escaping @MainActor (Bool) -> Void
    ) {
        cell.textLabel?.text = title
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = identifier
        let control = UISwitch()
        control.isOn = isOn
        control.addAction(UIAction { action in
            guard let control = action.sender as? UISwitch else { return }
            MainActor.assumeIsolated { changed(control.isOn) }
        }, for: .valueChanged)
        cell.accessoryView = control
    }

    private func chooseConnectionMethod() {
        let alert = UIAlertController(
            title: L10n.string("mobile.settings.connectionMethod", defaultValue: "Connection Method"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for method in MobileConnectionMethod.allCases {
            let title = method == .automatic
                ? L10n.string("mobile.settings.connectionMethod.automatic", defaultValue: "Auto-Connect")
                : L10n.string("mobile.settings.connectionMethod.tailscale", defaultValue: "Tailscale")
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.coordinator.connectionMethodStore.method = method
                self?.rebuildSections()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func chooseValue<Value>(
        title: String,
        values: [Value],
        label: (Value) -> String,
        selected: @escaping @MainActor (Value) -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for value in values {
            alert.addAction(UIAlertAction(title: label(value), style: .default) { _ in
                MainActor.assumeIsolated { selected(value) }
                self.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func toggleNotifications() {
        guard notificationTask == nil else { return }
        notificationTask = Task { [weak self] in
            guard let self else { return }
            if coordinator.pushCoordinator.isEnabled {
                await coordinator.pushCoordinator.disable()
            } else {
                _ = await coordinator.pushCoordinator.enable()
            }
            notificationTask = nil
            tableView.reloadData()
        }
    }

    private func confirmDeleteAccount() {
        let alert = UIAlertController(
            title: L10n.string("mobile.settings.deleteAccountTitle", defaultValue: "Delete Account?"),
            message: L10n.string(
                "mobile.settings.deleteAccountMessage",
                defaultValue: "This permanently deletes your cmux account and cmux data. You will be signed out on this device."
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("mobile.settings.deleteAccountCancel", defaultValue: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("mobile.settings.deleteAccountConfirm", defaultValue: "Delete Account"), style: .destructive) { [weak self] _ in
            self?.deleteAccount()
        })
        present(alert, animated: true)
    }

    private func deleteAccount() {
        guard accountTask == nil else { return }
        accountTask = Task { [weak self] in
            guard let self else { return }
            defer { accountTask = nil }
            do {
                _ = try await coordinator.auth.deleteAccount()
                dismiss(animated: true) { [weak coordinator] in coordinator?.signOut() }
            } catch {
                presentError(
                    title: L10n.string("mobile.settings.deleteAccountFailureTitle", defaultValue: "Account could not be deleted"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func presentError(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.ok", defaultValue: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func open(_ url: URL) {
        UIApplication.shared.open(url)
    }

    private var accountEmail: String {
        let value = coordinator.auth.currentUser?.primaryEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty
            ? L10n.string("mobile.settings.notSignedIn", defaultValue: "Not signed in")
            : value
    }

    private var accountDisplayName: String {
        let value = coordinator.auth.currentUser?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty
            ? L10n.string("mobile.settings.account", defaultValue: "Account")
            : value
    }

    private static var crashReportingEnabled: Bool {
        switch Bundle.main.object(forInfoDictionaryKey: "CMUXCrashReportingEnabled") {
        case let enabled as Bool: enabled
        case let enabled as String: enabled.caseInsensitiveCompare("NO") != .orderedSame
        default: true
        }
    }

    private static var telemetryTitle: String {
        L10n.string(
            crashReportingEnabled ? "mobile.settings.telemetry" : "mobile.settings.telemetryAnalyticsOnly",
            defaultValue: crashReportingEnabled ? "Share Analytics and Crash Reports" : "Share Anonymous Analytics"
        )
    }

    private static var telemetryFooter: String {
        L10n.string(
            crashReportingEnabled ? "mobile.settings.telemetryFooter" : "mobile.settings.telemetryAnalyticsOnlyFooter",
            defaultValue: crashReportingEnabled
                ? "When off, cmux does not send iPhone or iPad product analytics or crash reports."
                : "When off, cmux does not send iPhone or iPad product analytics."
        )
    }

    private static var supportURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "feedback@manaflow.com"
        components.queryItems = [URLQueryItem(
            name: "subject",
            value: L10n.string("mobile.settings.supportEmailSubject", defaultValue: "cmux iOS support")
        )]
        return components.url!
    }
}

@MainActor
private final class MobileComputersViewController: UITableViewController {
    private let store: CMUXMobileShellStore
    private var computers: [MobilePairedMac] = []

    init(store: CMUXMobileShellStore) {
        self.store = store
        super.init(style: .insetGrouped)
        title = L10n.string("mobile.settings.computers", defaultValue: "Computers")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "MobileComputersList"
        reload()
    }

    private func reload() {
        computers = store.displayPairedMacs
        if isViewLoaded { tableView.reloadData() }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        computers.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let computer = computers[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = computer.resolvedName
        let status = store.macConnectionStatuses[computer.id]
            ?? store.macConnectionStatuses[computer.macDeviceID]
        cell.detailTextLabel?.text = status?.label
            ?? L10n.string("mobile.connection.unavailable", defaultValue: "Disconnected")
        cell.imageView?.image = UIImage(systemName: computer.customIcon ?? "desktopcomputer")
            ?? UIImage(systemName: "desktopcomputer")
        cell.imageView?.tintColor = status == .connected ? .systemGreen : .secondaryLabel
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "MobileComputerRow-\(computer.id)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            MobileComputerDetailViewController(store: store, computer: computers[indexPath.row]),
            animated: true
        )
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let computer = computers[indexPath.row]
        let hide = UIContextualAction(
            style: .destructive,
            title: L10n.string("mobile.computers.hide", defaultValue: "Hide")
        ) { [weak self] _, _, completion in
            Task { [weak self] in
                guard let self else { return }
                await store.hideMac(
                    macDeviceID: computer.macDeviceID,
                    instanceTag: computer.instanceTag
                )
                reload()
                completion(true)
            }
        }
        hide.image = UIImage(systemName: "eye.slash")
        return UISwipeActionsConfiguration(actions: [hide])
    }
}

@MainActor
private final class MobileComputerDetailViewController: UITableViewController {
    private let store: CMUXMobileShellStore
    private var computer: MobilePairedMac

    init(store: CMUXMobileShellStore, computer: MobilePairedMac) {
        self.store = store
        self.computer = computer
        super.init(style: .insetGrouped)
        title = computer.resolvedName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: 3
        case 1: max(1, computer.routes.count)
        default: 3
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: L10n.string("mobile.computers.section.connection", defaultValue: "Connection")
        case 1: L10n.string("mobile.computers.section.routes", defaultValue: "Routes")
        default: L10n.string("mobile.computers.section.actions", defaultValue: "Actions")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        if indexPath.section == 0 {
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = L10n.string("mobile.computers.field.phone", defaultValue: "This phone")
                let status = store.macConnectionStatuses[computer.id]
                    ?? store.macConnectionStatuses[computer.macDeviceID]
                cell.detailTextLabel?.text = status?.label
            case 1:
                cell.textLabel?.text = L10n.string("mobile.computers.field.workspaces", defaultValue: "Workspaces")
                cell.detailTextLabel?.text = "\(store.workspaceCount(for: computer.macDeviceID, instanceTag: computer.instanceTag))"
            default:
                cell.textLabel?.text = L10n.string("mobile.computers.field.deviceID", defaultValue: "Device ID")
                cell.detailTextLabel?.text = computer.macDeviceID
            }
            cell.selectionStyle = .none
        } else if indexPath.section == 1 {
            if computer.routes.isEmpty {
                cell.textLabel?.text = L10n.string("mobile.computers.routes.none", defaultValue: "No saved routes")
                cell.selectionStyle = .none
            } else {
                let route = computer.routes[indexPath.row]
                cell.textLabel?.text = route.kind.rawValue
                cell.detailTextLabel?.text = Self.endpointDescription(route.endpoint)
                cell.selectionStyle = .none
            }
        } else {
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = L10n.string("mobile.computers.rename", defaultValue: "Rename")
                cell.imageView?.image = UIImage(systemName: "pencil")
            case 1:
                cell.textLabel?.text = L10n.string("mobile.disconnected.retry", defaultValue: "Reconnect")
                cell.imageView?.image = UIImage(systemName: "arrow.clockwise")
            default:
                cell.textLabel?.text = L10n.string("mobile.computers.hide", defaultValue: "Hide")
                cell.textLabel?.textColor = .systemRed
                cell.imageView?.image = UIImage(systemName: "eye.slash")
                cell.imageView?.tintColor = .systemRed
            }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 2 else { return }
        switch indexPath.row {
        case 0: rename()
        case 1:
            Task { [store, computer] in
                _ = await store.reconnectToMac(
                    macDeviceID: computer.macDeviceID,
                    instanceTag: computer.instanceTag
                )
            }
        default:
            Task { [weak self, store, computer] in
                await store.hideMac(macDeviceID: computer.macDeviceID, instanceTag: computer.instanceTag)
                self?.navigationController?.popViewController(animated: true)
            }
        }
    }

    private func rename() {
        let alert = UIAlertController(
            title: L10n.string("mobile.computers.rename", defaultValue: "Rename"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { [computer] field in field.text = computer.customName ?? computer.displayName }
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.save", defaultValue: "Save"), style: .default) { [weak self] _ in
            guard let self else { return }
            let name = alert.textFields?.first?.text
            Task {
                await store.updateMacCustomization(
                    macDeviceID: computer.macDeviceID,
                    instanceTag: computer.instanceTag,
                    customName: name,
                    customColor: computer.customColor,
                    customIcon: computer.customIcon
                )
                computer.customName = name
                title = computer.resolvedName
            }
        })
        present(alert, animated: true)
    }

    private static func endpointDescription(_ endpoint: CmxAttachEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            "\(host):\(port)"
        case .peer(let identity, _):
            String(identity.endpointID.prefix(12))
        case .url(let url):
            url
        }
    }
}

@MainActor
private final class MobileIntroductionViewController: UIViewController {
    override func loadView() {
        let root = UIView()
        root.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = L10n.string("mobile.onboarding.agents.title", defaultValue: "Your agents, from anywhere")
        title.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(
            for: .systemFont(ofSize: 34, weight: .bold)
        )
        title.textAlignment = .center
        title.numberOfLines = 0
        let body = UILabel()
        body.text = L10n.string("mobile.onboarding.agents.message", defaultValue: "Follow every workspace and answer your coding agents from your phone.")
        body.font = .preferredFont(forTextStyle: .body)
        body.textColor = .secondaryLabel
        body.textAlignment = .center
        body.numberOfLines = 0
        let done = UIButton(type: .system)
        done.configuration = .filled()
        done.configuration?.title = L10n.string("mobile.settings.done", defaultValue: "Done")
        done.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, body, done])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.layoutMarginsGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.layoutMarginsGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }
}

@MainActor
private final class MobileSetupHelpViewController: UITableViewController {
    private let steps: [(String, String)] = [
        (
            L10n.string("mobile.setupHelp.account.title", defaultValue: "Use the same account"),
            L10n.string("mobile.setupHelp.account.message", defaultValue: "Sign in to cmux with the same account on your phone and Mac.")
        ),
        (
            L10n.string("mobile.setupHelp.mac.title", defaultValue: "Open cmux on your Mac"),
            L10n.string("mobile.setupHelp.mac.message", defaultValue: "Keep the Mac awake and cmux running while you connect.")
        ),
        (
            L10n.string("mobile.setupHelp.network.title", defaultValue: "Check the network"),
            L10n.string("mobile.setupHelp.network.message", defaultValue: "Allow Local Network access and verify your selected connection method.")
        ),
    ]

    init() {
        super.init(style: .insetGrouped)
        title = L10n.string("mobile.settings.setUpYourMac", defaultValue: "Set Up Computer")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { steps.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = steps[indexPath.row].0
        cell.detailTextLabel?.text = steps[indexPath.row].1
        cell.detailTextLabel?.numberOfLines = 0
        cell.imageView?.image = UIImage(systemName: "\(indexPath.row + 1).circle")
        cell.selectionStyle = .none
        return cell
    }
}
#endif
