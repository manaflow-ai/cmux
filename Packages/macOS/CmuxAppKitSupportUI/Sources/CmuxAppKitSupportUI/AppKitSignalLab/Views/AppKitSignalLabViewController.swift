#if canImport(AppKit)

import AppKit

@MainActor
final class AppKitSignalLabViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let model: AppKitSignalLabModel
    private var effects: [SignalEffect] = []

    private let tableView = NSTableView()
    private let newTaskField = NSTextField()
    private let addTaskButton = NSButton()
    private let clearCompletedButton = NSButton()
    private let searchField = NSSearchField()
    private let filterControl = NSSegmentedControl()
    private let visibleCountLabel = NSTextField(labelWithString: "")
    private let activeValueLabel = NSTextField(labelWithString: "")
    private let throughputValueLabel = NSTextField(labelWithString: "")
    private let healthValueLabel = NSTextField(labelWithString: "")
    private let progressValueLabel = NSTextField(labelWithString: "")
    private let selectionTitleLabel = NSTextField(labelWithString: "")
    private let selectionOwnerLabel = NSTextField(labelWithString: "")
    private let selectionStatusLabel = NSTextField(labelWithString: "")
    private let selectionProgressLabel = NSTextField(labelWithString: "")
    private let selectionProgressIndicator = NSProgressIndicator()
    private let capacitySlider = NSSlider(value: 0.74, minValue: 0.25, maxValue: 1, target: nil, action: nil)
    private let automationSwitch = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let priorityPopup = NSPopUpButton()
    private let advanceButton = NSButton()
    private let blockButton = NSButton()
    private let activityLabel = NSTextField(wrappingLabelWithString: "")
    private let pulseView = SignalLabPulseView()
    private let allFilterButton = NSButton()
    private let activeFilterButton = NSButton()
    private let blockedFilterButton = NSButton()
    private let completeFilterButton = NSButton()
    private let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    init(model: AppKitSignalLabModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildInterface()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installBindings()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        model.filteredTasks.get().count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let tasks = model.filteredTasks.get()
        guard tasks.indices.contains(row), let tableColumn else { return nil }
        let task = tasks[row]
        let identifier = tableColumn.identifier
        if identifier.rawValue == "done" {
            let button = tableView.makeView(withIdentifier: identifier, owner: self) as? NSButton
                ?? makeCompletionButton(identifier: identifier)
            button.tag = row
            button.state = task.status == .complete ? .on : .off
            button.toolTip = String(localized: "debug.signalLab.todo.toggle", defaultValue: "Toggle completion")
            return button
        }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)

        switch identifier.rawValue {
        case "work":
            cell.textField?.stringValue = task.title
            cell.imageView?.image = NSImage(systemSymbolName: task.status.systemImageName, accessibilityDescription: task.status.title)
            cell.imageView?.contentTintColor = statusColor(task.status)
        case "owner":
            cell.textField?.stringValue = task.owner
        case "status":
            cell.textField?.stringValue = task.status.title
            cell.textField?.textColor = statusColor(task.status)
        case "progress":
            cell.textField?.stringValue = formattedPercent(task.progress)
            cell.textField?.alignment = .right
        default:
            break
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        model.selectTask(at: tableView.selectedRow)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === newTaskField {
            model.draftTaskTitle.set(field.stringValue)
        } else if field === searchField {
            model.query.set(field.stringValue)
        }
    }

    private func buildInterface() {
        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 18
        rootStack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        rootStack.addArrangedSubview(makeHeader())
        rootStack.addArrangedSubview(makeComposer())
        rootStack.addArrangedSubview(makeMetricStrip())
        let splitView = makeSplitView()
        rootStack.addArrangedSubview(splitView)
        splitView.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -44).isActive = true
        splitView.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func makeHeader() -> NSView {
        let title = NSTextField(labelWithString: String(localized: "debug.signalLab.title", defaultValue: "Signal Todo List"))
        title.font = .systemFont(ofSize: 26, weight: .bold)
        let subtitle = NSTextField(labelWithString: String(localized: "debug.signalLab.subtitle", defaultValue: "A native AppKit todo app driven by Solid-style signals."))
        subtitle.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4

        let simulateButton = NSButton(
            title: String(localized: "debug.signalLab.simulate", defaultValue: "Run demo step"),
            target: self,
            action: #selector(runSimulationStep)
        )
        simulateButton.bezelStyle = .rounded
        simulateButton.controlSize = .large
        simulateButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)

        let spacer = NSView()
        let header = NSStackView(views: [titleStack, spacer, simulateButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.widthAnchor.constraint(greaterThanOrEqualToConstant: 700).isActive = true
        return header
    }

    private func makeComposer() -> NSView {
        newTaskField.placeholderString = String(
            localized: "debug.signalLab.todo.placeholder",
            defaultValue: "What needs to be done?"
        )
        newTaskField.delegate = self
        newTaskField.target = self
        newTaskField.action = #selector(addDraftTask)

        addTaskButton.title = String(localized: "debug.signalLab.todo.add", defaultValue: "Add Todo")
        addTaskButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addTaskButton.imagePosition = .imageLeading
        addTaskButton.bezelStyle = .rounded
        addTaskButton.target = self
        addTaskButton.action = #selector(addDraftTask)

        clearCompletedButton.title = String(
            localized: "debug.signalLab.todo.clearCompleted",
            defaultValue: "Clear Completed"
        )
        clearCompletedButton.bezelStyle = .rounded
        clearCompletedButton.target = self
        clearCompletedButton.action = #selector(clearCompleted)

        let composer = NSStackView(views: [newTaskField, addTaskButton, clearCompletedButton])
        composer.orientation = .horizontal
        composer.spacing = 10
        newTaskField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        composer.widthAnchor.constraint(greaterThanOrEqualToConstant: 700).isActive = true
        return composer
    }

    private func makeMetricStrip() -> NSView {
        let metrics = NSStackView(views: [
            makeMetricCard(
                title: String(localized: "debug.signalLab.metric.active", defaultValue: "REMAINING"),
                valueLabel: activeValueLabel
            ),
            makeMetricCard(
                title: String(localized: "debug.signalLab.metric.throughput", defaultValue: "COMPLETED"),
                valueLabel: throughputValueLabel
            ),
            makeMetricCard(
                title: String(localized: "debug.signalLab.metric.health", defaultValue: "COMPLETION"),
                valueLabel: healthValueLabel
            ),
            makeMetricCard(
                title: String(localized: "debug.signalLab.metric.progress", defaultValue: "AVG PROGRESS"),
                valueLabel: progressValueLabel
            ),
        ])
        metrics.orientation = .horizontal
        metrics.distribution = .fillEqually
        metrics.spacing = 12
        return metrics
    }

    private func makeMetricCard(title: String, valueLabel: NSTextField) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = NSColor.separatorColor
        box.fillColor = NSColor.controlBackgroundColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold)

        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -11),
            box.heightAnchor.constraint(equalToConstant: 72),
        ])
        return box
    }

    private func makeSplitView() -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(makeSidebar())
        splitView.addArrangedSubview(makeWorkList())
        splitView.addArrangedSubview(makeInspector())
        splitView.subviews[0].widthAnchor.constraint(equalToConstant: 185).isActive = true
        splitView.subviews[2].widthAnchor.constraint(equalToConstant: 275).isActive = true
        return splitView
    }

    private func makeSidebar() -> NSView {
        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .withinWindow
        container.state = .active

        let heading = NSTextField(labelWithString: String(localized: "debug.signalLab.sidebar.heading", defaultValue: "TODO LISTS"))
        heading.font = .systemFont(ofSize: 11, weight: .bold)
        heading.textColor = .secondaryLabelColor

        configureFilterButton(allFilterButton, filter: .all, tag: 0)
        configureFilterButton(activeFilterButton, filter: .active, tag: 1)
        configureFilterButton(blockedFilterButton, filter: .blocked, tag: 2)
        configureFilterButton(completeFilterButton, filter: .complete, tag: 3)

        let stack = NSStackView(views: [heading, allFilterButton, activeFilterButton, blockedFilterButton, completeFilterButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
        ])
        return container
    }

    private func configureFilterButton(_ button: NSButton, filter: AppKitSignalLabFilter, tag: Int) {
        button.title = filter.title
        button.tag = tag
        button.target = self
        button.action = #selector(selectFilter(_:))
        button.bezelStyle = .recessed
        button.alignment = .left
        button.imagePosition = .imageLeading
        button.image = NSImage(systemSymbolName: tag == 0 ? "square.grid.2x2" : "circle.fill", accessibilityDescription: nil)
        button.widthAnchor.constraint(equalToConstant: 157).isActive = true
    }

    private func makeWorkList() -> NSView {
        searchField.placeholderString = String(localized: "debug.signalLab.search.placeholder", defaultValue: "Search todos or lists")
        searchField.delegate = self

        filterControl.segmentCount = 4
        filterControl.setLabel(String(localized: "debug.signalLab.filter.all.short", defaultValue: "All"), forSegment: 0)
        filterControl.setLabel(String(localized: "debug.signalLab.filter.active", defaultValue: "Open"), forSegment: 1)
        filterControl.setLabel(String(localized: "debug.signalLab.filter.blocked", defaultValue: "Blocked"), forSegment: 2)
        filterControl.setLabel(String(localized: "debug.signalLab.filter.complete", defaultValue: "Done"), forSegment: 3)
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(selectSegment(_:))
        filterControl.segmentStyle = .capsule

        visibleCountLabel.textColor = .secondaryLabelColor
        visibleCountLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let toolbar = NSStackView(views: [searchField, filterControl, visibleCountLabel])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true

        configureTable()
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView

        let stack = NSStackView(views: [toolbar, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        return stack
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 36
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.doubleAction = #selector(advanceSelected)
        tableView.target = self

        let columns: [(String, String, CGFloat)] = [
            ("done", "", 32),
            ("work", String(localized: "debug.signalLab.column.work", defaultValue: "Todo"), 210),
            ("owner", String(localized: "debug.signalLab.column.owner", defaultValue: "List"), 85),
            ("status", String(localized: "debug.signalLab.column.status", defaultValue: "Status"), 75),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = identifier == "done" ? 32 : (identifier == "work" ? 150 : 60)
            column.maxWidth = identifier == "done" ? 32 : .greatestFiniteMagnitude
            tableView.addTableColumn(column)
        }
    }

    private func makeCompletionButton(identifier: NSUserInterfaceItemIdentifier) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleTodoCompletion(_:)))
        button.identifier = identifier
        button.setButtonType(.switch)
        return button
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        if identifier.rawValue == "work" {
            let imageView = NSImageView()
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7),
            ])
        } else {
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6).isActive = true
        }
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeInspector() -> NSView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let container = NSVisualEffectView()
        container.material = .contentBackground
        container.blendingMode = .withinWindow

        let heading = NSTextField(labelWithString: String(localized: "debug.signalLab.inspector.heading", defaultValue: "TODO DETAILS"))
        heading.font = .systemFont(ofSize: 11, weight: .bold)
        heading.textColor = .secondaryLabelColor
        selectionTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        selectionTitleLabel.maximumNumberOfLines = 2
        selectionOwnerLabel.textColor = .secondaryLabelColor
        selectionStatusLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        selectionProgressIndicator.minValue = 0
        selectionProgressIndicator.maxValue = 1
        selectionProgressIndicator.style = .bar
        selectionProgressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let progressHeader = NSStackView(views: [
            NSTextField(labelWithString: String(localized: "debug.signalLab.inspector.progress", defaultValue: "Progress")),
            NSView(),
            selectionProgressLabel,
        ])
        progressHeader.orientation = .horizontal

        priorityPopup.addItems(withTitles: [
            String(localized: "debug.signalLab.priority.critical", defaultValue: "Critical priority"),
            String(localized: "debug.signalLab.priority.high", defaultValue: "High priority"),
            String(localized: "debug.signalLab.priority.normal", defaultValue: "Normal priority"),
        ])
        priorityPopup.target = self
        priorityPopup.action = #selector(changePriority(_:))

        capacitySlider.target = self
        capacitySlider.action = #selector(changeCapacity(_:))
        capacitySlider.isContinuous = true
        let capacityLabel = NSTextField(labelWithString: String(localized: "debug.signalLab.capacity", defaultValue: "Focus capacity"))

        automationSwitch.title = String(localized: "debug.signalLab.automation", defaultValue: "Auto-schedule dependencies")
        automationSwitch.target = self
        automationSwitch.action = #selector(toggleAutomation(_:))

        advanceButton.title = String(localized: "debug.signalLab.advance", defaultValue: "Advance Todo")
        advanceButton.target = self
        advanceButton.action = #selector(advanceSelected)
        advanceButton.bezelStyle = .rounded
        blockButton.title = String(localized: "debug.signalLab.toggleBlock", defaultValue: "Toggle Blocked")
        blockButton.target = self
        blockButton.action = #selector(toggleBlock)
        blockButton.bezelStyle = .rounded
        let actionStack = NSStackView(views: [advanceButton, blockButton])
        actionStack.orientation = .horizontal
        actionStack.distribution = .fillEqually

        let pulseTitle = NSTextField(labelWithString: String(localized: "debug.signalLab.pulse", defaultValue: "TODO PULSE"))
        pulseTitle.font = .systemFont(ofSize: 11, weight: .bold)
        pulseTitle.textColor = .secondaryLabelColor
        pulseView.heightAnchor.constraint(equalToConstant: 58).isActive = true

        let activityTitle = NSTextField(labelWithString: String(localized: "debug.signalLab.activity.heading", defaultValue: "RECENT EFFECTS"))
        activityTitle.font = .systemFont(ofSize: 11, weight: .bold)
        activityTitle.textColor = .secondaryLabelColor
        activityLabel.font = .systemFont(ofSize: 11)
        activityLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            heading,
            selectionTitleLabel,
            selectionOwnerLabel,
            selectionStatusLabel,
            separator(),
            progressHeader,
            selectionProgressIndicator,
            priorityPopup,
            capacityLabel,
            capacitySlider,
            automationSwitch,
            actionStack,
            separator(),
            pulseTitle,
            pulseView,
            activityTitle,
            activityLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        container.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = container
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            container.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            selectionProgressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            priorityPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            capacitySlider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pulseView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            activityLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return scrollView
    }

    private func separator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func installBindings() {
        effects.append(model.graph.createEffect { [weak self] _ in
            guard let self else { return }
            let tasks = model.filteredTasks.get()
            tableView.reloadData()
            visibleCountLabel.stringValue = String(
                format: String(localized: "debug.signalLab.visibleCount", defaultValue: "%lld visible"),
                Int64(tasks.count)
            )
            pulseView.samples = tasks.map(\.progress)
            if let selectedID = model.selectedTaskID.get(),
               let index = tasks.firstIndex(where: { $0.id == selectedID }) {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
        })

        effects.append(model.graph.createEffect { [weak self] _ in
            guard let self else { return }
            let metrics = model.metrics.get()
            let allTasks = model.tasks.get()
            let remainingCount = allTasks.count - metrics.completedCount
            activeValueLabel.stringValue = "\(remainingCount)"
            throughputValueLabel.stringValue = "\(metrics.completedCount)"
            healthValueLabel.stringValue = formattedPercent(
                allTasks.isEmpty ? 0 : Double(metrics.completedCount) / Double(allTasks.count)
            )
            progressValueLabel.stringValue = formattedPercent(metrics.averageProgress)
            capacitySlider.doubleValue = metrics.capacity
            automationSwitch.state = metrics.automationEnabled ? .on : .off
            allFilterButton.title = "\(AppKitSignalLabFilter.all.title)  \(allTasks.count)"
            let openCount = allTasks.filter { AppKitSignalLabFilter.active.includes($0.status) }.count
            activeFilterButton.title = "\(AppKitSignalLabFilter.active.title)  \(openCount)"
            blockedFilterButton.title = "\(AppKitSignalLabFilter.blocked.title)  \(metrics.blockedCount)"
            completeFilterButton.title = "\(AppKitSignalLabFilter.complete.title)  \(metrics.completedCount)"
            clearCompletedButton.isEnabled = metrics.completedCount > 0
        })

        effects.append(model.graph.createEffect { [weak self] _ in
            guard let self else { return }
            let draft = model.draftTaskTitle.get()
            if newTaskField.stringValue != draft {
                newTaskField.stringValue = draft
            }
            addTaskButton.isEnabled = model.canAddTask.get()
        })

        effects.append(model.graph.createEffect { [weak self] _ in
            guard let self else { return }
            guard let task = model.selectedTask.get() else {
                selectionTitleLabel.stringValue = String(localized: "debug.signalLab.inspector.none", defaultValue: "No todo selected")
                selectionOwnerLabel.stringValue = ""
                selectionStatusLabel.stringValue = ""
                selectionProgressLabel.stringValue = ""
                selectionProgressIndicator.doubleValue = 0
                priorityPopup.isEnabled = false
                advanceButton.isEnabled = false
                blockButton.isEnabled = false
                return
            }
            selectionTitleLabel.stringValue = task.title
            selectionOwnerLabel.stringValue = task.owner
            selectionStatusLabel.stringValue = task.status.title
            selectionStatusLabel.textColor = statusColor(task.status)
            selectionProgressLabel.stringValue = formattedPercent(task.progress)
            selectionProgressIndicator.doubleValue = task.progress
            priorityPopup.selectItem(at: max(0, min(2, task.priority - 1)))
            priorityPopup.isEnabled = true
            advanceButton.isEnabled = task.status != .complete
            blockButton.isEnabled = task.status != .complete
        })

        effects.append(model.graph.createEffect { [weak self] _ in
            guard let self else { return }
            activityLabel.stringValue = model.activity.get().map { "• \($0)" }.joined(separator: "\n")
        })
    }

    private func statusColor(_ status: AppKitSignalLabStatus) -> NSColor {
        switch status {
        case .queued: .secondaryLabelColor
        case .running: .systemBlue
        case .review: .systemPurple
        case .blocked: .systemOrange
        case .complete: .systemGreen
        }
    }

    private func formattedPercent(_ value: Double) -> String {
        percentFormatter.string(from: NSNumber(value: value)) ?? ""
    }

    @objc private func selectFilter(_ sender: NSButton) {
        filterControl.selectedSegment = sender.tag
        applyFilter(index: sender.tag)
    }

    @objc private func selectSegment(_ sender: NSSegmentedControl) {
        applyFilter(index: sender.selectedSegment)
    }

    private func applyFilter(index: Int) {
        let filters: [AppKitSignalLabFilter] = [.all, .active, .blocked, .complete]
        guard filters.indices.contains(index) else { return }
        model.filter.set(filters[index])
    }

    @objc private func runSimulationStep() {
        model.runSimulationStep()
    }

    @objc private func addDraftTask() {
        model.draftTaskTitle.set(newTaskField.stringValue)
        model.addDraftTask()
    }

    @objc private func clearCompleted() {
        model.clearCompletedTasks()
    }

    @objc private func toggleTodoCompletion(_ sender: NSButton) {
        model.toggleCompletion(at: sender.tag)
    }

    @objc private func advanceSelected() {
        model.advanceSelectedTask()
    }

    @objc private func toggleBlock() {
        model.toggleBlockedForSelectedTask()
    }

    @objc private func changeCapacity(_ sender: NSSlider) {
        model.capacity.set(sender.doubleValue)
    }

    @objc private func toggleAutomation(_ sender: NSButton) {
        model.automationEnabled.set(sender.state == .on)
    }

    @objc private func changePriority(_ sender: NSPopUpButton) {
        model.setSelectedPriority(sender.indexOfSelectedItem + 1)
    }
}

#endif
