public import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// The Task Manager page: one row per cmux process with CPU and memory, sortable by any column,
/// and Kill Process on the selected row (the button and the row menu).
///
/// An AppKit `NSTableView` (plans/cmux-next/no-swiftui-DESIGN.md). It follows the model's snapshot
/// (one sample a second) by reloading its rows in place and keeping the selection; a column click
/// sorts. Selection writes back to ``TaskManagerModel/selection``.
///
/// ```swift
/// let view = TaskManagerView(model: model)
/// ```
public final class TaskManagerView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let model: TaskManagerModel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: TaskManagerStrings.empty)
    private let total = NSTextField(labelWithString: "")
    private let killButton = NSButton()
    /// The rows in the order shown (the model's order, sorted by the table's sort descriptors).
    private(set) var shownRows: [TaskManagerRow] = []
    private var observation: Task<Void, Never>?
    private var applyingSelection = false

    private enum Column: String, CaseIterable {
        case task, process, pid, cpu, memory
    }

    /// Makes the page over `model`; it follows the model until it leaves its window.
    public init(model: TaskManagerModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        build()
        reload()
        observation = Task { [weak self, model] in
            for await _ in ObservationStream({ model.snapshot }) {
                self?.reload()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    private func build() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = title(column)
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            switch column {
            case .task: tableColumn.width = 200
            case .process: tableColumn.width = 140
            case .pid, .cpu: tableColumn.minWidth = 50; tableColumn.width = 70
            case .memory: tableColumn.minWidth = 70; tableColumn.width = 90
            }
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.setAccessibilityIdentifier("cmux.taskManager.table")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        total.textColor = .secondaryLabelColor
        total.font = .monospacedDigitSystemFont(ofSize: TypeScale.body, weight: TypeScale.regular)
        killButton.title = TaskManagerStrings.killButton
        killButton.bezelStyle = .push
        killButton.target = self
        killButton.action = #selector(killSelected)
        killButton.setAccessibilityIdentifier("cmux.taskManager.kill")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [total, spacer, killButton])
        footer.orientation = .horizontal
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        footer.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        for view in [scroll, empty, divider, footer] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func title(_ column: Column) -> String {
        switch column {
        case .task: TaskManagerStrings.columnTask
        case .process: TaskManagerStrings.columnProcess
        case .pid: TaskManagerStrings.columnPID
        case .cpu: TaskManagerStrings.columnCPU
        case .memory: TaskManagerStrings.columnMemory
        }
    }

    /// Shows the model's snapshot now: rows in place, the selection kept, the total and Kill updated.
    func reload() {
        shownRows = sorted(model.snapshot.rows)
        applyingSelection = true
        table.reloadData()
        let selected = IndexSet(shownRows.indices.filter { model.selection.contains(shownRows[$0].id) })
        table.selectRowIndexes(selected, byExtendingSelection: false)
        applyingSelection = false
        empty.isHidden = !model.snapshot.rows.isEmpty
        total.stringValue = TaskManagerStrings.total(ResourceFormat.line(model.snapshot.total))
        killButton.isEnabled = model.selectedRow != nil
    }

    private func sorted(_ rows: [TaskManagerRow]) -> [TaskManagerRow] {
        guard let sort = table.sortDescriptors.first, let key = sort.key, let column = Column(rawValue: key) else { return rows }
        let ascending = sort.ascending
        func less(_ a: TaskManagerRow, _ b: TaskManagerRow) -> Bool {
            switch column {
            case .task: a.task.localizedStandardCompare(b.task) == .orderedAscending
            case .process: a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .pid: a.pid < b.pid
            case .cpu: a.cpuSortValue < b.cpuSortValue
            case .memory: a.memoryBytes < b.memoryBytes
            }
        }
        return rows.sorted { ascending ? less($0, $1) : less($1, $0) }
    }

    private func text(_ row: TaskManagerRow, _ column: Column) -> String {
        switch column {
        case .task: row.task
        case .process: row.name
        case .pid: row.id.host == ProcessKey.localHost ? String(row.pid) : row.id.description
        case .cpu: row.cpu.map { ResourceFormat.cpu($0) } ?? Strings.pending
        case .memory: ResourceFormat.memory(row.memoryBytes)
        }
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    public func numberOfRows(in tableView: NSTableView) -> Int { shownRows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue), shownRows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell.\(column.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            if column != .task && column != .process {
                field.font = .monospacedDigitSystemFont(ofSize: TypeScale.body, weight: TypeScale.regular)
            }
            return field
        }()
        cell.stringValue = text(shownRows[row], column)
        return cell
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        reload()
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        model.selection = Set(table.selectedRowIndexes.compactMap { shownRows.indices.contains($0) ? shownRows[$0].id : nil })
        killButton.isEnabled = model.selectedRow != nil
    }

    // MARK: Row menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard shownRows.indices.contains(row) else { return }
        let item = NSMenuItem(title: TaskManagerStrings.killMenu, action: #selector(killClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = shownRows[row].id
        menu.addItem(item)
    }

    @objc private func killClicked(_ item: NSMenuItem) {
        guard let key = item.representedObject as? ProcessKey else { return }
        model.kill(key)
    }

    @objc private func killSelected() {
        guard let row = model.selectedRow else { return }
        model.kill(row.id)
    }
}
