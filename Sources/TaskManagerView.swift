import AppKit
import Observation

/// Native Task Manager surface backed by a recycled AppKit table.
@MainActor
final class CmuxTaskManagerView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Item {
        case section(String)
        case row(CmuxTaskManagerRow)
    }

    private let model: CmuxTaskManagerModel
    private let tableView = CmuxTaskManagerTableView()
    private let scrollView = NSScrollView()
    private let progress = NSProgressIndicator()
    private let processToggle = NSButton(checkboxWithTitle: String(
        localized: "taskManager.showProcesses",
        defaultValue: "Processes"
    ), target: nil, action: nil)
    private let statusContainer = NSView()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private var metricValues: [String: NSTextField] = [:]
    private var items: [Item] = []
    private var contextRow: CmuxTaskManagerRow?

    init(model: CmuxTaskManagerModel) {
        self.model = model
        super.init(frame: .zero)
        setupView()
        refreshFromModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupView() {
        let title = NSTextField(labelWithString: String(localized: "taskManager.title", defaultValue: "Task Manager"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel(String(localized: "taskManager.refreshing", defaultValue: "Refreshing"))

        processToggle.target = self
        processToggle.action = #selector(toggleProcesses)
        let refreshButton = NSButton(
            title: String(localized: "taskManager.refresh", defaultValue: "Refresh"),
            target: self,
            action: #selector(refresh)
        )
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.imagePosition = .imageLeading
        refreshButton.bezelStyle = .rounded

        let toolbar = NSStackView(views: [title, progress, NSView(), processToggle, refreshButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        toolbar.setHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.arrangedSubviews[2].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let summary = makeSummaryView()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.target = self
        tableView.action = #selector(activateSelectedRow)
        tableView.menuProvider = { [weak self] row in self?.menu(for: row) }
        addColumn("name", title: String(localized: "taskManager.column.name", defaultValue: "Name"), width: 540)
        addColumn("cpu", title: String(localized: "taskManager.column.cpu", defaultValue: "CPU"), width: 82)
        addColumn("memory", title: String(localized: "taskManager.column.memory", defaultValue: "Memory"), width: 96)
        addColumn("processes", title: String(localized: "taskManager.column.processes", defaultValue: "Proc"), width: 70)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        statusTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        statusTitle.alignment = .center
        statusDetail.font = .systemFont(ofSize: 12)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.alignment = .center
        statusDetail.maximumNumberOfLines = 0
        let statusStack = NSStackView(views: [statusTitle, statusDetail])
        statusStack.orientation = .vertical
        statusStack.alignment = .centerX
        statusStack.spacing = 8
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.centerXAnchor.constraint(equalTo: statusContainer.centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            statusStack.widthAnchor.constraint(lessThanOrEqualTo: statusContainer.widthAnchor, constant: -64),
        ])

        let separator1 = NSBox(); separator1.boxType = .separator
        let separator2 = NSBox(); separator2.boxType = .separator
        let root = NSStackView(views: [toolbar, separator1, summary, separator2])
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        for child in [root, scrollView, statusContainer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 820),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 480),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusContainer.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            statusContainer.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            statusContainer.topAnchor.constraint(equalTo: scrollView.topAnchor),
            statusContainer.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
    }

    private func makeSummaryView() -> NSView {
        let metrics = [
            ("cpu", String(localized: "taskManager.summary.cpu", defaultValue: "CPU")),
            ("memory", String(localized: "taskManager.summary.memory", defaultValue: "Memory")),
            ("appFootprint", String(localized: "taskManager.summary.appFootprint", defaultValue: "App Footprint")),
            ("childRSS", String(localized: "taskManager.summary.childRSS", defaultValue: "Child RSS")),
            ("processes", String(localized: "taskManager.summary.processes", defaultValue: "Processes")),
            ("updated", String(localized: "taskManager.summary.updated", defaultValue: "Updated")),
        ]
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 24
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        for (key, label) in metrics {
            let title = NSTextField(labelWithString: label)
            title.font = .systemFont(ofSize: 11)
            title.textColor = .secondaryLabelColor
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            metricValues[key] = value
            let stack = NSStackView(views: [title, value])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            row.addArrangedSubview(stack)
        }
        row.addArrangedSubview(NSView())
        return row
    }

    private func addColumn(_ identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = identifier == "name" ? 260 : width
        column.maxWidth = identifier == "name" ? .greatestFiniteMagnitude : width
        column.resizingMask = identifier == "name" ? .autoresizingMask : []
        tableView.addTableColumn(column)
    }

    private func refreshFromModel() {
        withObservationTracking {
            processToggle.state = model.includesProcesses ? .on : .off
            if model.isRefreshing || model.isInitialLoading {
                progress.startAnimation(nil)
            } else {
                progress.stopAnimation(nil)
            }
            updateSummary()
            rebuildItems()
            updateStatus()
            updateSortIndicator()
            tableView.reloadData()
        } onChange: { [weak self] in
            Task { @MainActor in self?.refreshFromModel() }
        }
    }

    private func updateSummary() {
        metricValues["cpu"]?.stringValue = CmuxTaskManagerFormat.cpu(model.snapshot.total.cpuPercent)
        metricValues["memory"]?.stringValue = CmuxTaskManagerFormat.bytes(model.snapshot.total.memoryBytes)
        metricValues["processes"]?.stringValue = "\(model.snapshot.total.processCount)"
        metricValues["updated"]?.stringValue = model.snapshot.updatedText
        let diagnostic = model.snapshot.memoryDiagnostic
        metricValues["appFootprint"]?.stringValue = diagnostic.map { CmuxTaskManagerFormat.bytes($0.appFootprintBytes) } ?? "–"
        metricValues["childRSS"]?.stringValue = diagnostic.map { CmuxTaskManagerFormat.bytes($0.childRSSBytes) } ?? "–"
    }

    private func rebuildItems() {
        var next: [Item] = []
        append(model.sortedAgentRows, title: String(localized: "taskManager.section.codingAgents", defaultValue: "Coding Agents"), to: &next)
        append(model.sortedAggregateRows, title: String(localized: "taskManager.section.programTotals", defaultValue: "Program Totals"), to: &next)
        append(model.sortedChildMemoryRows, title: String(localized: "taskManager.section.childProcessRSS", defaultValue: "Child Process RSS"), to: &next)
        if !model.sortedRows.isEmpty,
           (!model.sortedAgentRows.isEmpty || !model.sortedAggregateRows.isEmpty || !model.sortedChildMemoryRows.isEmpty) {
            next.append(.section(String(localized: "taskManager.section.hierarchy", defaultValue: "Hierarchy")))
        }
        next.append(contentsOf: model.sortedRows.map(Item.row))
        items = next
    }

    private func append(_ rows: [CmuxTaskManagerRow], title: String, to items: inout [Item]) {
        guard !rows.isEmpty else { return }
        items.append(.section(title))
        items.append(contentsOf: rows.map(Item.row))
    }

    private func updateStatus() {
        if let error = model.errorMessage {
            statusTitle.stringValue = String(localized: "taskManager.error.title", defaultValue: "Unable to load resource usage")
            statusDetail.stringValue = error
            statusContainer.isHidden = false
            scrollView.isHidden = true
        } else if model.isInitialLoading {
            statusTitle.stringValue = String(localized: "taskManager.loading.title", defaultValue: "Loading resource usage")
            statusDetail.stringValue = ""
            statusContainer.isHidden = false
            scrollView.isHidden = true
        } else if items.isEmpty {
            statusTitle.stringValue = String(localized: "taskManager.empty.title", defaultValue: "No resource usage")
            statusDetail.stringValue = String(localized: "taskManager.empty.detail", defaultValue: "Open a workspace, terminal, or browser surface to see it here.")
            statusContainer.isHidden = false
            scrollView.isHidden = true
        } else {
            statusContainer.isHidden = true
            scrollView.isHidden = false
        }
    }

    private func updateSortIndicator() {
        for column in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: column)
        }
        let identifier: String
        switch model.sortOrder.column {
        case .name: identifier = "name"
        case .cpu: identifier = "cpu"
        case .memory: identifier = "memory"
        case .processes: identifier = "processes"
        }
        guard let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == identifier }) else { return }
        let symbol = model.sortOrder.direction == .ascending ? "chevron.up" : "chevron.down"
        tableView.setIndicatorImage(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), in: column)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard items.indices.contains(row), case .section = items[row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row) else { return 32 }
        if case .section = items[row] { return 28 }
        return 38
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let column: CmuxTaskManagerSortOrder.Column
        switch tableColumn.identifier.rawValue {
        case "cpu": column = .cpu
        case "memory": column = .memory
        case "processes": column = .processes
        default: column = .name
        }
        model.sort(by: column)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let tableColumn else { return nil }
        switch items[row] {
        case .section(let title):
            guard tableColumn.identifier.rawValue == "name" else { return NSView() }
            let cell = reusableTextCell(identifier: "section", tableView: tableView)
            cell.textField?.stringValue = title
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        case .row(let taskRow):
            if tableColumn.identifier.rawValue == "name" {
                let id = NSUserInterfaceItemIdentifier("nameCell")
                let cell = (tableView.makeView(withIdentifier: id, owner: self) as? CmuxTaskManagerNameCell) ?? {
                    let made = CmuxTaskManagerNameCell(); made.identifier = id; return made
                }()
                cell.configure(taskRow)
                return cell
            }
            let cell = reusableTextCell(identifier: tableColumn.identifier.rawValue, tableView: tableView)
            cell.textField?.alignment = .right
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
            switch tableColumn.identifier.rawValue {
            case "cpu": cell.textField?.stringValue = CmuxTaskManagerFormat.cpu(taskRow.resources.cpuPercent)
            case "memory": cell.textField?.stringValue = CmuxTaskManagerFormat.bytes(taskRow.resources.memoryBytes)
            default: cell.textField?.stringValue = "\(taskRow.resources.processCount)"
            }
            cell.alphaValue = taskRow.isDimmed ? 0.68 : 1
            return cell
        }
    }

    private func reusableTextCell(identifier: String, tableView: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = id
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func toggleProcesses() { model.includesProcesses = processToggle.state == .on }
    @objc private func refresh() { model.refresh(force: true) }
    @objc private func activateSelectedRow() {
        guard case let .row(row)? = item(at: tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow) else { return }
        model.viewBestTarget(for: row)
    }

    private func item(at index: Int) -> Item? { items.indices.contains(index) ? items[index] : nil }

    private func menu(for index: Int) -> NSMenu? {
        guard case let .row(row)? = item(at: index) else { return nil }
        contextRow = row
        let menu = NSMenu()
        if row.canViewWorkspace {
            menu.addItem(menuItem(String(localized: "taskManager.contextMenu.viewWorkspace", defaultValue: "View Workspace"), action: #selector(viewWorkspace)))
        }
        if row.canViewTerminal {
            menu.addItem(menuItem(String(localized: "taskManager.contextMenu.viewTerminal", defaultValue: "View Terminal"), action: #selector(viewTerminal)))
        }
        if row.canKillProcess {
            if row.canViewWorkspace || row.canViewTerminal { menu.addItem(.separator()) }
            menu.addItem(menuItem(String(localized: "taskManager.contextMenu.killProcess", defaultValue: "Kill Process..."), action: #selector(killProcess)))
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func viewWorkspace() {
        guard let contextRow else { return }
        model.viewWorkspace(for: contextRow)
    }
    @objc private func viewTerminal() {
        guard let contextRow else { return }
        model.viewTerminal(for: contextRow)
    }
    @objc private func killProcess() {
        guard let contextRow else { return }
        model.killProcess(for: contextRow)
    }
}

@MainActor
private final class CmuxTaskManagerTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menuProvider?(row)
    }
}

@MainActor
private final class CmuxTaskManagerNameCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var row: CmuxTaskManagerRow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyDown
        title.font = .systemFont(ofSize: 12.5)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        addSubview(icon); addSubview(title); addSubview(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ row: CmuxTaskManagerRow) {
        self.row = row
        title.stringValue = row.title
        detail.stringValue = row.detail
        if let asset = row.agentAssetName {
            icon.image = NSImage(named: NSImage.Name(asset))
            icon.contentTintColor = nil
        } else {
            icon.image = NSImage(systemSymbolName: row.kind.systemImage, accessibilityDescription: nil)
            icon.contentTintColor = row.kind.tint
        }
        detail.isHidden = row.detail.isEmpty
        alphaValue = row.isDimmed ? 0.68 : 1
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let row else { return }
        let x = CGFloat(row.level) * 14 + 4
        icon.frame = NSRect(x: x, y: max(0, (bounds.height - 14) / 2), width: 14, height: 14)
        title.frame = NSRect(x: x + 19, y: row.detail.isEmpty ? max(0, (bounds.height - 16) / 2) : 18, width: max(0, bounds.width - x - 23), height: 16)
        detail.frame = NSRect(x: x + 19, y: 3, width: max(0, bounds.width - x - 23), height: 14)
    }
}
