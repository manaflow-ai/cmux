import AppKit
import CmuxSettings
import Foundation

/// AppKit-owned settings root with native sidebar search and schema-driven controls.
@MainActor
public final class SettingsWindowRoot: NSSplitViewController {
    public static let navigationRequestName = Notification.Name("cmux.settings.navigate")
    public static let sidebarToggleRequestName = Notification.Name("cmux.settings.toggleSidebar")

    private let runtime: SettingsRuntime
    private let onContentAppear: @MainActor () -> Void
    private let sidebarController: SettingsSidebarController
    private let detailController: SettingsDetailController
    private let sidebarItem: NSSplitViewItem
    private var notificationTask: Task<Void, Never>?
    private var toggleTask: Task<Void, Never>?
    private var didReportContentAppearance = false

    public init(
        runtime: SettingsRuntime,
        onContentAppear: @escaping @MainActor () -> Void = {}
    ) {
        self.runtime = runtime
        self.onContentAppear = onContentAppear
        sidebarController = SettingsSidebarController(searchIndex: runtime.searchIndex)
        detailController = SettingsDetailController(runtime: runtime)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        super.init(nibName: nil, bundle: nil)

        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: detailController))

        sidebarController.onSelect = { [weak self] entry in
            guard let self else { return }
            self.select(entry: entry, highlight: !self.sidebarController.searchText.isEmpty)
        }

        let restored = UserDefaults.standard.string(forKey: "selectedSettingsSection")
            .flatMap(SettingsSectionID.init(rawValue:)) ?? .account
        select(section: restored, anchorID: "section:\(restored.rawValue)", highlight: false)
        startNotificationTasks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        notificationTask?.cancel()
        toggleTask?.cancel()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        guard !didReportContentAppearance else { return }
        didReportContentAppearance = true
        onContentAppear()
    }

    /// Search seam retained for focused navigation tests and host integrations.
    public func sidebarEntries(matching query: String) -> [SettingsSearchIndex.Entry] {
        runtime.searchIndex.match(query)
    }

    private func startNotificationTasks() {
        notificationTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: Self.navigationRequestName
            ) {
                guard !Task.isCancelled, let self else { return }
                applyNavigation(notification)
            }
        }
        toggleTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: Self.sidebarToggleRequestName
            ) {
                guard !Task.isCancelled, let self else { return }
                sidebarItem.animator().isCollapsed.toggle()
            }
        }
    }

    private func applyNavigation(_ notification: Notification) {
        guard let raw = notification.userInfo?["target"] as? String,
              let section = SettingsSectionID(rawValue: raw) else { return }
        let anchor = notification.userInfo?["anchor"] as? String
            ?? "section:\(section.rawValue)"
        let highlight = notification.userInfo?["highlight"] as? Bool ?? false
        select(section: section, anchorID: anchor, highlight: highlight)
    }

    private func select(entry: SettingsSearchIndex.Entry, highlight: Bool) {
        let section: SettingsSectionID
        switch entry.kind {
        case .section:
            let raw = entry.id.replacingOccurrences(of: "section:", with: "")
            section = SettingsSectionID(rawValue: raw) ?? .account
        case .setting(let parent):
            section = parent
        }
        select(section: section, anchorID: entry.anchorID, highlight: highlight)
        NotificationCenter.default.post(
            name: Self.navigationRequestName,
            object: self,
            userInfo: [
                "target": section.rawValue,
                "anchor": entry.anchorID,
                "highlight": highlight,
            ]
        )
    }

    private func select(
        section: SettingsSectionID,
        anchorID: String,
        highlight: Bool
    ) {
        UserDefaults.standard.set(section.rawValue, forKey: "selectedSettingsSection")
        sidebarController.select(section: section)
        detailController.show(section: section, anchorID: anchorID, highlight: highlight)
    }
}

@MainActor
private final class SettingsSidebarController: NSViewController,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate
{
    var onSelect: @MainActor (SettingsSearchIndex.Entry) -> Void = { _ in }
    private let searchIndex: SettingsSearchIndex
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var entries: [SettingsSearchIndex.Entry]

    var searchText: String { searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(searchIndex: SettingsSearchIndex) {
        self.searchIndex = searchIndex
        entries = searchIndex.match("")
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        searchField.placeholderString = String(
            localized: "settings.search.prompt",
            defaultValue: "Search"
        )
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings.sidebar"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 42
        tableView.style = .sourceList

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func controlTextDidChange(_ notification: Notification) {
        entries = searchIndex.match(searchField.stringValue)
        tableView.reloadData()
        if !entries.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(
            systemSymbolName: entry.symbolName,
            accessibilityDescription: entry.title
        ) ?? NSImage())
        image.contentTintColor = .secondaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: entry.title)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(title)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 17),
            image.heightAnchor.constraint(equalToConstant: 17),
            title.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard entries.indices.contains(tableView.selectedRow) else { return }
        onSelect(entries[tableView.selectedRow])
    }

    func select(section: SettingsSectionID) {
        guard searchText.isEmpty,
              let row = entries.firstIndex(where: { $0.id == "section:\(section.rawValue)" }) else {
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }
}

@MainActor
private final class SettingsDetailController: NSViewController {
    private let runtime: SettingsRuntime
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let stackView = NSStackView()
    private var rowsByAnchor: [String: NSView] = [:]
    private var highlightTask: Task<Void, Never>?
    private var accountObservationGeneration = 0
    private var retainedTargets: [AnyObject] = []

    init(runtime: SettingsRuntime) {
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { highlightTask?.cancel() }

    override func loadView() {
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView

        documentView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24),
        ])
        view = scrollView
    }

    func show(section: SettingsSectionID, anchorID: String, highlight: Bool) {
        loadViewIfNeeded()
        rebuild(section: section)
        view.layoutSubtreeIfNeeded()
        guard let target = rowsByAnchor[anchorID]
            ?? rowsByAnchor["section:\(section.rawValue)"] else { return }
        scrollView.contentView.scrollToVisible(target.frame.insetBy(dx: 0, dy: -20))
        guard highlight else { return }
        pulseHighlight(target)
    }

    private func rebuild(section: SettingsSectionID) {
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rowsByAnchor.removeAll(keepingCapacity: true)
        retainedTargets.removeAll(keepingCapacity: true)

        let header = SettingsNativeSectionHeader(title: section.title, symbolName: section.symbolName)
        stackView.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        rowsByAnchor["section:\(section.rawValue)"] = header

        if section == .account {
            addAccountContent()
        } else if section == .sleepyMode {
            addSleepyModeContent()
        } else {
            let keys = runtime.catalog.all.filter { Self.section(for: $0.id) == section }
            for key in keys {
                let row = SettingEditorRowView(key: key, runtime: runtime)
                stackView.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
                rowsByAnchor[key.id] = row
                if let anchor = runtime.searchIndex.anchorID(forSettingsPath: key.id) {
                    rowsByAnchor[anchor] = row
                }
            }
            if keys.isEmpty {
                addEmptyState()
            }
        }
        addSectionActions(section)
    }

    private func addAccountContent() {
        guard let flow = runtime.accountFlow else {
            addEmptyState()
            return
        }
        accountObservationGeneration &+= 1
        observeAccount(flow, generation: accountObservationGeneration)
    }

    private func observeAccount(_ flow: any AccountFlow, generation: Int) {
        let snapshot = withObservationTracking {
            AccountSnapshot(
                identity: flow.currentIdentity,
                teams: flow.availableTeams,
                selectedTeamID: flow.selectedTeamID,
                isWorking: flow.isWorkingOnAuth,
                isProActive: flow.isProActive,
                canManageBilling: flow.canManageBilling
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.accountObservationGeneration == generation else { return }
                self.rebuild(section: .account)
            }
        }

        let title = snapshot.identity.map { identity in
            identity.displayName.isEmpty ? identity.email : identity.displayName
        } ?? String(localized: "settings.account.signedOut", defaultValue: "Not signed in")
        let subtitle = snapshot.identity?.email ?? String(
            localized: "settings.account.signIn.detail",
            defaultValue: "Sign in to sync your cmux account."
        )
        addInformationRow(title: title, detail: subtitle)

        if snapshot.identity == nil {
            addActionButton(
                title: String(localized: "settings.account.signIn", defaultValue: "Sign In"),
                enabled: !snapshot.isWorking,
                action: { flow.startSignIn() }
            )
        } else {
            if !snapshot.teams.isEmpty {
                let picker = NSPopUpButton()
                for team in snapshot.teams { picker.addItem(withTitle: team.displayName) }
                if let selected = snapshot.selectedTeamID,
                   let index = snapshot.teams.firstIndex(where: { $0.id == selected }) {
                    picker.selectItem(at: index)
                }
                let target = AccountTeamTarget(flow: flow, teams: snapshot.teams, picker: picker)
                retainedTargets.append(target)
                picker.target = target
                picker.action = #selector(AccountTeamTarget.selectTeam(_:))
                stackView.addArrangedSubview(picker)
            }
            addActionButton(
                title: snapshot.canManageBilling
                    ? String(localized: "settings.account.manageBilling", defaultValue: "Manage Billing")
                    : String(localized: "settings.account.upgrade", defaultValue: "Upgrade to Pro"),
                enabled: !snapshot.isWorking,
                action: {
                    if snapshot.canManageBilling {
                        flow.openBillingPortal()
                    } else {
                        flow.openProUpgrade()
                    }
                }
            )
            addActionButton(
                title: String(localized: "settings.account.signOut", defaultValue: "Sign Out"),
                enabled: !snapshot.isWorking,
                action: { Task { await flow.signOut() } }
            )
        }
    }

    private func addSleepyModeContent() {
        let store = runtime.hostActions.sleepyModeStore()
        addChoiceRow(
            title: String(localized: "settings.sleepy.theme", defaultValue: "Theme"),
            choices: SleepyTheme.allCases.map { ($0.rawValue, $0.rawValue) },
            selected: store.theme.rawValue,
            onSelect: { store.theme = SleepyTheme(rawValue: $0) ?? .cmux }
        )
        addChoiceRow(
            title: String(localized: "settings.sleepy.mascot", defaultValue: "Mascot"),
            choices: SleepyMascot.allCases.map { ($0.rawValue, $0.rawValue) },
            selected: store.mascot.rawValue,
            onSelect: { store.mascot = SleepyMascot(rawValue: $0) ?? .cmux }
        )
        addChoiceRow(
            title: String(localized: "settings.sleepy.glow", defaultValue: "Glow"),
            choices: SleepyGlow.allCases.map { ($0.rawValue, $0.rawValue) },
            selected: store.glow.rawValue,
            onSelect: { store.glow = SleepyGlow(rawValue: $0) ?? .black }
        )
        addBooleanRow(title: String(localized: "settings.sleepy.moon", defaultValue: "Moon"), value: store.showMoon) { store.showMoon = $0 }
        addBooleanRow(title: String(localized: "settings.sleepy.stars", defaultValue: "Stars"), value: store.showStars) { store.showStars = $0 }
        addBooleanRow(title: String(localized: "settings.sleepy.clock", defaultValue: "Clock"), value: store.showClock) { store.showClock = $0 }
        addBooleanRow(title: String(localized: "settings.sleepy.status", defaultValue: "Battery and Wi-Fi"), value: store.showStatus) { store.showStatus = $0 }
        addBooleanRow(title: String(localized: "settings.sleepy.pets", defaultValue: "Agent pets"), value: store.showPets) { store.showPets = $0 }
    }

    private func addSectionActions(_ section: SettingsSectionID) {
        let actions = runtime.hostActions
        switch section {
        case .app:
            addActionButton(title: String(localized: "settings.notifications.test", defaultValue: "Send Test Notification")) { actions.sendTestNotification() }
            addActionButton(title: String(localized: "settings.feedback.send", defaultValue: "Send Feedback")) { actions.sendFeedback() }
        case .terminal:
            addActionButton(title: String(localized: "settings.terminal.openConfig", defaultValue: "Open Terminal Config")) { actions.openTerminalConfigWindow() }
        case .mobile:
            addActionButton(title: String(localized: "settings.mobile.pair", defaultValue: "Pair iPhone or iPad")) { actions.openMobilePairingWindow() }
        case .browser, .browserImport:
            addActionButton(title: String(localized: "settings.browser.import", defaultValue: "Import Browser Data")) { actions.openBrowserImportFlow() }
            addActionButton(title: String(localized: "settings.browser.clearHistory", defaultValue: "Clear Browser History")) { actions.clearBrowserHistory() }
        case .settingsJSON:
            addActionButton(title: String(localized: "settings.json.openExternal", defaultValue: "Open cmux.json in Editor")) { actions.openConfigInExternalEditor() }
        case .sleepyMode:
            addActionButton(title: String(localized: "settings.sleepy.preview", defaultValue: "Preview")) { actions.sleepyModePreview() }
            addActionButton(title: String(localized: "settings.sleepy.start", defaultValue: "Start Sleepy Mode")) { actions.sleepyModeStart() }
        case .reset:
            addActionButton(
                title: String(localized: "settings.reset.all", defaultValue: "Reset All Settings"),
                action: { [weak self] in self?.resetAll() }
            )
        default:
            break
        }
    }

    private func resetAll() {
        let runtime = runtime
        Task { [weak self] in
            await runtime.userDefaultsStore.resetAll(runtime.catalog.all)
            for key in runtime.catalog.all {
                do {
                    try await key.resetEditorValue(
                        runtime.userDefaultsStore,
                        runtime.jsonStore,
                        runtime.secretStore
                    )
                } catch {
                    runtime.errorLog.record(error, keyID: key.id)
                }
            }
            runtime.hostActions.resetAllSettingsSideEffects()
            self?.rebuild(section: .reset)
        }
    }

    private func addActionButton(
        title: String,
        enabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) {
        let button = SettingsActionButton(title: title, action: action)
        button.isEnabled = enabled
        stackView.addArrangedSubview(button)
    }

    private func addInformationRow(title: String, detail: String) {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 3
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(detailLabel)
        stackView.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    private func addEmptyState() {
        let label = NSTextField(wrappingLabelWithString: String(
            localized: "settings.section.noCatalogSettings",
            defaultValue: "This section contains actions managed by cmux."
        ))
        label.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(label)
    }

    private func addBooleanRow(title: String, value: Bool, onChange: @escaping @MainActor (Bool) -> Void) {
        let row = SettingsNativeLabeledRow(title: title)
        let toggle = NSSwitch()
        toggle.state = value ? .on : .off
        let target = SettingsBooleanTarget(toggle: toggle, onChange: onChange)
        toggle.target = target
        toggle.action = #selector(SettingsBooleanTarget.changed(_:))
        row.retain(target)
        row.setControl(toggle)
        stackView.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    private func addChoiceRow(
        title: String,
        choices: [(String, String)],
        selected: String,
        onSelect: @escaping @MainActor (String) -> Void
    ) {
        let row = SettingsNativeLabeledRow(title: title)
        let picker = NSPopUpButton()
        for choice in choices { picker.addItem(withTitle: choice.1) }
        picker.selectItem(at: max(0, choices.firstIndex(where: { $0.0 == selected }) ?? 0))
        let target = SettingsChoiceTarget(picker: picker, choices: choices.map(\.0), onSelect: onSelect)
        picker.target = target
        picker.action = #selector(SettingsChoiceTarget.changed(_:))
        row.retain(target)
        row.setControl(picker)
        stackView.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    private func pulseHighlight(_ view: NSView) {
        highlightTask?.cancel()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        highlightTask = Task { [weak view] in
            try? await ContinuousClock().sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            view?.layer?.borderWidth = 0
        }
    }

    private static func section(for keyID: String) -> SettingsSectionID {
        let prefix = keyID.split(separator: ".").first.map(String.init) ?? keyID
        switch prefix {
        case "account": return .account
        case "app", "notifications": return .app
        case "terminal", "fileEditor": return .terminal
        case "textBox": return .textBox
        case "mobile": return .mobile
        case "iroh", "networking": return .networking
        case "sidebar", "sidebarAppearance", "paneChrome", "workspaceGroups": return .sidebarAppearance
        case "customSidebars": return .customSidebars
        case "betaFeatures": return .betaFeatures
        case "automation", "integrations": return .automation
        case "browser", "markdown": return .browser
        case "shortcuts": return .keyboardShortcuts
        case "workspaceColors", "canvas": return .workspaceColors
        default: return .app
        }
    }
}

@MainActor
private final class SettingEditorRowView: NSView, NSTextFieldDelegate {
    private let key: AnySettingKey
    private let runtime: SettingsRuntime
    private let valueControlContainer = NSView()
    private let progress = NSProgressIndicator()
    private var currentValue: SettingValue
    private var loadTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var textField: NSTextField?
    private var toggle: NSSwitch?

    init(key: AnySettingKey, runtime: SettingsRuntime) {
        self.key = key
        self.runtime = runtime
        currentValue = key.editorDefaultValue
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        loadTask?.cancel()
        writeTask?.cancel()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor

        let label = NSTextField(labelWithString: Self.title(for: key.id, index: runtime.searchIndex))
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = key.id
        label.translatesAutoresizingMaskIntoConstraints = false
        valueControlContainer.translatesAutoresizingMaskIntoConstraints = false

        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        progress.translatesAutoresizingMaskIntoConstraints = false
        valueControlContainer.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: valueControlContainer.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: valueControlContainer.centerYAnchor),
        ])

        let reset = NSButton(
            title: String(localized: "settings.reset", defaultValue: "Reset"),
            target: self,
            action: #selector(resetPressed(_:))
        )
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(valueControlContainer)
        addSubview(reset)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.38),
            valueControlContainer.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            valueControlContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueControlContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            reset.leadingAnchor.constraint(equalTo: valueControlContainer.trailingAnchor, constant: 10),
            reset.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            reset.centerYAnchor.constraint(equalTo: centerYAnchor),
            reset.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }

    private func load() {
        loadTask?.cancel()
        let key = key
        let runtime = runtime
        loadTask = Task { [weak self] in
            do {
                let value = try await key.readEditorValue(
                    runtime.userDefaultsStore,
                    runtime.jsonStore,
                    runtime.secretStore
                )
                guard !Task.isCancelled else { return }
                self?.show(value)
            } catch {
                self?.showError(error)
            }
        }
    }

    private func show(_ value: SettingValue) {
        currentValue = value
        valueControlContainer.subviews.forEach { $0.removeFromSuperview() }
        switch value {
        case .boolean(let enabled):
            let toggle = NSSwitch()
            toggle.state = enabled ? .on : .off
            toggle.target = self
            toggle.action = #selector(toggleChanged(_:))
            self.toggle = toggle
            install(control: toggle)
        default:
            let field: NSTextField
            if case .secretFile = key.kind {
                field = NSSecureTextField()
            } else {
                field = NSTextField()
            }
            field.stringValue = value.editingText
            field.delegate = self
            field.target = self
            field.action = #selector(textCommitted(_:))
            field.lineBreakMode = .byTruncatingTail
            textField = field
            install(control: field)
        }
    }

    private func install(control: NSControl) {
        control.translatesAutoresizingMaskIntoConstraints = false
        valueControlContainer.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: valueControlContainer.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: valueControlContainer.trailingAnchor),
            control.topAnchor.constraint(equalTo: valueControlContainer.topAnchor),
            control.bottomAnchor.constraint(equalTo: valueControlContainer.bottomAnchor),
            valueControlContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        commit(text: field.stringValue)
    }

    @objc private func textCommitted(_ sender: NSTextField) { commit(text: sender.stringValue) }

    private func commit(text: String) {
        do {
            save(try currentValue.replacingValue(with: text))
        } catch {
            textField?.stringValue = currentValue.editingText
            showError(error)
        }
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        save(.boolean(sender.state == .on))
    }

    @objc private func resetPressed(_ sender: NSButton) {
        writeTask?.cancel()
        let key = key
        let runtime = runtime
        writeTask = Task { [weak self] in
            do {
                try await key.resetEditorValue(
                    runtime.userDefaultsStore,
                    runtime.jsonStore,
                    runtime.secretStore
                )
                guard !Task.isCancelled else { return }
                self?.load()
            } catch {
                self?.showError(error)
            }
        }
    }

    private func save(_ value: SettingValue) {
        writeTask?.cancel()
        let previous = currentValue
        currentValue = value
        let key = key
        let runtime = runtime
        writeTask = Task { [weak self] in
            do {
                try await key.writeEditorValue(
                    value,
                    runtime.userDefaultsStore,
                    runtime.jsonStore,
                    runtime.secretStore
                )
                guard !Task.isCancelled else { return }
                self?.applyHostSideEffects()
            } catch {
                guard !Task.isCancelled else { return }
                self?.show(previous)
                self?.showError(error)
            }
        }
    }

    private func applyHostSideEffects() {
        if key.id.hasPrefix("automation.") { runtime.hostActions.socketControlConfigurationDidChange() }
        if key.id.hasPrefix("shortcuts.") { runtime.hostActions.notifyShortcutSettingsDidChange() }
    }

    private func showError(_ error: Error) {
        runtime.errorLog.record(error, keyID: key.id)
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }

    private static func title(for keyID: String, index: SettingsSearchIndex) -> String {
        if let anchor = index.anchorID(forSettingsPath: keyID),
           let entry = index.entries.first(where: { $0.anchorID == anchor }) {
            return entry.title
        }
        let leaf = keyID.split(separator: ".").last.map(String.init) ?? keyID
        return leaf
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

@MainActor
private final class SettingsNativeSectionHeader: NSView {
    init(title: String, symbolName: String) {
        super.init(frame: .zero)
        let image = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: title) ?? NSImage())
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .preferredFont(forTextStyle: .title1)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            image.leadingAnchor.constraint(equalTo: leadingAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 24),
            image.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class SettingsActionButton: NSButton {
    private let handler: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(run(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run(_ sender: Any?) { handler() }
}

@MainActor
private final class SettingsNativeLabeledRow: NSView {
    private let controlHost = NSView()
    private var retainedTargets: [AnyObject] = []

    init(title: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        controlHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(controlHost)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            controlHost.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            controlHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            controlHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            controlHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func retain(_ target: AnyObject) { retainedTargets.append(target) }

    func setControl(_ control: NSControl) {
        control.translatesAutoresizingMaskIntoConstraints = false
        controlHost.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: controlHost.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: controlHost.trailingAnchor),
            control.topAnchor.constraint(equalTo: controlHost.topAnchor),
            control.bottomAnchor.constraint(equalTo: controlHost.bottomAnchor),
        ])
    }
}

@MainActor
private final class SettingsBooleanTarget: NSObject {
    weak var toggle: NSSwitch?
    let onChange: @MainActor (Bool) -> Void
    init(toggle: NSSwitch, onChange: @escaping @MainActor (Bool) -> Void) {
        self.toggle = toggle
        self.onChange = onChange
    }
    @objc func changed(_ sender: NSSwitch) { onChange(sender.state == .on) }
}

@MainActor
private final class SettingsChoiceTarget: NSObject {
    weak var picker: NSPopUpButton?
    let choices: [String]
    let onSelect: @MainActor (String) -> Void
    init(picker: NSPopUpButton, choices: [String], onSelect: @escaping @MainActor (String) -> Void) {
        self.picker = picker
        self.choices = choices
        self.onSelect = onSelect
    }
    @objc func changed(_ sender: NSPopUpButton) {
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        onSelect(choices[sender.indexOfSelectedItem])
    }
}

@MainActor
private final class AccountTeamTarget: NSObject {
    weak var flow: (any AccountFlow)?
    let teams: [AccountTeamSummary]
    weak var picker: NSPopUpButton?
    init(flow: any AccountFlow, teams: [AccountTeamSummary], picker: NSPopUpButton) {
        self.flow = flow
        self.teams = teams
        self.picker = picker
    }
    @objc func selectTeam(_ sender: NSPopUpButton) {
        guard teams.indices.contains(sender.indexOfSelectedItem) else { return }
        flow?.selectedTeamID = teams[sender.indexOfSelectedItem].id
    }
}

private struct AccountSnapshot {
    let identity: AccountIdentity?
    let teams: [AccountTeamSummary]
    let selectedTeamID: String?
    let isWorking: Bool
    let isProActive: Bool
    let canManageBilling: Bool
}
