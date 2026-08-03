import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import Observation

/// Main-actor owner of the Vault table lifecycle and its immutable row snapshot.
@MainActor
final class SessionIndexTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("vault-session")
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("vault-session-cell")

    private weak var containerView: SessionIndexTableContainerView?
    private var rows: [SessionIndexTableRow] = []
    private var environment: SessionIndexTableEnvironmentSnapshot?
    private let rowHeightCalculator = SessionIndexTableRowHeightCalculator()
    private let popoverPresenter: SessionIndexTablePopoverPresenter
    private var isApplyingRows = false
    private lazy var mutationScheduler = SessionIndexTableMutationScheduler(
        applyFlush: { [weak self] in self?.flushApply($0) }
    )

    init(popoverPresenter: SessionIndexTablePopoverPresenter? = nil) {
        self.popoverPresenter = popoverPresenter ?? SessionIndexTablePopoverPresenter()
        super.init()
    }

    func makeContainerView() -> SessionIndexTableContainerView {
        let container = SessionIndexTableContainerView()
        containerView = container

        let table = container.tableView
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsTypeSelect = false
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.rowHeight = 24
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scrollView = container.scrollView
        scrollView.documentView = table
        table.frame = scrollView.contentView.bounds
        table.autoresizingMask = [.width]
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        scrollView.applySidebarOverlayScrollerConfiguration()

        return container
    }

    func apply(
        rows nextRows: [SessionIndexTableRow],
        environment nextEnvironment: SessionIndexTableEnvironmentSnapshot
    ) {
        mutationScheduler.stageApply(
            SessionIndexTableApplyInput(rows: nextRows, environment: nextEnvironment)
        )
    }

    func dismantle() {
        popoverPresenter.dismiss()
    }

    private func flushApply(_ input: SessionIndexTableApplyInput) {
        guard let table = containerView?.tableView else { return }
        let nextRows = input.rows
        let nextEnvironment = input.environment
        let previousRows = rows
        let hasStructuralChanges = previousRows.map(\.id) != nextRows.map(\.id)
        let hasEnvironmentChanges = environment?.hasEquivalentPresentation(
            to: nextEnvironment
        ) != true
        rows = nextRows
        environment = nextEnvironment
        isApplyingRows = true
        defer {
            isApplyingRows = false
            refreshVisibleCellPresentations(in: table)
            reconcilePresentation(in: table)
        }

        if hasStructuralChanges || hasEnvironmentChanges {
            table.reloadData()
            return
        }

        let changedRows = IndexSet(nextRows.indices.filter { index in
            !previousRows[index].hasEquivalentContent(to: nextRows[index])
        })
        guard !changedRows.isEmpty else { return }
        table.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
        table.noteHeightOfRows(withIndexesChanged: changedRows)
    }

    private func refreshVisibleCellPresentations(in table: NSTableView) {
        let visibleRows = table.rows(in: table.visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        let visibleIndexes = visibleRows.location..<NSMaxRange(visibleRows)
        for rowIndex in visibleIndexes where rows.indices.contains(rowIndex) {
            (table.view(
                atColumn: 0,
                row: rowIndex,
                makeIfNecessary: false
            ) as? SessionIndexTableCellView)?.updatePresentation(from: rows[rowIndex])
        }
    }

    private func reconcilePresentation(in table: NSTableView) {
        guard let presentation = rows.lazy.compactMap(\.popoverPresentation).first else {
            popoverPresenter.dismiss()
            return
        }
        guard let rowIndex = rows.firstIndex(where: {
            $0.id == .section(presentation.identity.sectionKey)
        }) else {
            popoverPresenter.dismiss()
            return
        }
        guard let cell = table.view(
            atColumn: 0,
            row: rowIndex,
            makeIfNecessary: false
        ) as? SessionIndexTableCellView else {
            return
        }
        guard let anchorRect = cell.popoverAnchorRect(for: presentation.identity) else {
            return
        }
        popoverPresenter.reconcile(
            presentation,
            relativeTo: anchorRect,
            of: cell
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return tableView.rowHeight }
        return rowHeightCalculator.height(
            for: rows[row],
            environment: environment ?? .fallback
        )
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self)
            as? SessionIndexTableCellView) ?? SessionIndexTableCellView()
        cell.identifier = Self.cellIdentifier
        cell.onPopoverAnchorChange = { [weak self, weak tableView] in
            guard let self, let tableView else { return }
            guard !self.isApplyingRows else { return }
            self.reconcilePresentation(in: tableView)
        }
        cell.configure(
            row: rows[row],
            environment: environment ?? .fallback
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard !isApplyingRows else { return }
        reconcilePresentation(in: tableView)
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        guard popoverPresenter.isAnchored(in: rowView) else { return }
        if isApplyingRows {
            popoverPresenter.dismiss()
        } else {
            popoverPresenter.dismissAndNotify()
        }
    }
}

/// AppKit owner for the Vault toolbar, loading/empty states, and native table.
@MainActor
final class SessionIndexNativeViewController: NSViewController {
    private static let collapsedRowLimit = 5

    private let tableController = SessionIndexTableController()
    private let dragCoordinator = SessionDragCoordinator()
    private let toolbar = NSStackView()
    private let bodyContainer = NSView()
    private let separator = NSBox()
    private let scopeButton = NSButton()
    private let reloadButton = NSButton()
    private var groupingButtons: [SessionGrouping: NSButton] = [:]
    private var tableContainer: SessionIndexTableContainerView?
    private var storeObservationGeneration: UInt64 = 0
    private var dragCancelMonitor: Any?
    private var collapsedSections: Set<SectionKey> = []
    private var popoverIdentity: SessionIndexTablePopoverIdentity?
    private var store: SessionIndexStore
    private var onResume: ((SessionEntry) -> Void)?

    init(store: SessionIndexStore, onResume: ((SessionEntry) -> Void)?) {
        self.store = store
        self.onResume = onResume
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = SessionIndexNativeRootView()
        root.onAppearanceChange = { [weak self] in self?.render() }

        configureToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        root.addSubview(toolbar)
        root.addSubview(separator)
        root.addSubview(bodyContainer)
        installRightSidebarChromeGeometryReporter(in: toolbar, role: .secondaryBar)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: RightSidebarChromeMetrics.barHorizontalPadding),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -RightSidebarChromeMetrics.barHorizontalPadding),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            bodyContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        observeStore()
        installDragCancelMonitor()
        if store.entries.isEmpty, !store.isLoading { store.reload() }
        render()
    }

    func update(store: SessionIndexStore, onResume: ((SessionEntry) -> Void)?) {
        self.onResume = onResume
        guard self.store !== store else {
            if isViewLoaded { render() }
            return
        }
        self.store = store
        collapsedSections.removeAll()
        popoverIdentity = nil
        if isViewLoaded {
            observeStore()
            if store.entries.isEmpty, !store.isLoading { store.reload() }
            render()
        }
    }

    func teardown() {
        storeObservationGeneration &+= 1
        if let dragCancelMonitor {
            NSEvent.removeMonitor(dragCancelMonitor)
            self.dragCancelMonitor = nil
        }
        tableController.dismantle()
    }

    deinit {
        if let dragCancelMonitor { NSEvent.removeMonitor(dragCancelMonitor) }
    }

    private func configureToolbar() {
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        toolbar.distribution = .fill

        for grouping in SessionGrouping.allCases {
            let button = NSButton(title: grouping.label, target: self, action: #selector(selectGrouping(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("SessionGroupingButton.\(grouping.rawValue)")
            button.image = NSImage(systemSymbolName: grouping.symbolName, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.font = .systemFont(ofSize: RightSidebarChromeControlStyle.labelSize)
            button.toolTip = grouping.label
            button.setAccessibilityLabel(grouping.label)
            button.setAccessibilityIdentifier("rightSidebarSecondaryControl_\(grouping.rawValue)")
            installRightSidebarChromeGeometryReporter(
                in: button,
                role: .named("rightSidebarSecondaryControl_\(grouping.rawValue)")
            )
            groupingButtons[grouping] = button
            toolbar.addArrangedSubview(button)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)

        scopeButton.setButtonType(.switch)
        scopeButton.title = String(localized: "sessionIndex.scope.thisFolder", defaultValue: "This folder only")
        scopeButton.controlSize = .small
        scopeButton.font = .systemFont(ofSize: 11)
        scopeButton.target = self
        scopeButton.action = #selector(toggleScope)
        scopeButton.identifier = NSUserInterfaceItemIdentifier("SessionScopeToggle.thisFolder")
        scopeButton.setAccessibilityIdentifier("rightSidebarSecondaryControl_scope")
        installRightSidebarChromeGeometryReporter(
            in: scopeButton,
            role: .named("rightSidebarSecondaryControl_scope")
        )
        toolbar.addArrangedSubview(scopeButton)

        reloadButton.title = ""
        reloadButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: String(localized: "sessionIndex.reload.tooltip", defaultValue: "Reload Vault")
        )
        reloadButton.imagePosition = .imageOnly
        reloadButton.isBordered = false
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        reloadButton.toolTip = String(localized: "sessionIndex.reload.tooltip", defaultValue: "Reload Vault")
        reloadButton.setAccessibilityLabel(reloadButton.toolTip)
        toolbar.addArrangedSubview(reloadButton)
    }

    private func observeStore() {
        storeObservationGeneration &+= 1
        observeStoreChanges(generation: storeObservationGeneration)
    }

    private func observeStoreChanges(generation: UInt64) {
        withObservationTracking {
            _ = store.entries
            _ = store.isLoading
            _ = store.scopeToCurrentDirectory
            _ = store.currentDirectory
            _ = store.grouping
            _ = store.agentOrder
            _ = store.directoryOrder
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.storeObservationGeneration == generation else { return }
                self.observeStoreChanges(generation: generation)
                self.render()
            }
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        for (grouping, button) in groupingButtons {
            let selected = grouping == store.grouping
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        }
        scopeButton.state = store.scopeToCurrentDirectory ? .on : .off
        scopeButton.isEnabled = store.currentDirectory != nil
        reloadButton.isEnabled = !store.isLoading

        if store.isLoading, store.entries.isEmpty {
            showState(
                title: String(localized: "sessionIndex.loading", defaultValue: "Loading Vault…"),
                subtitle: nil,
                showsSpinner: true
            )
        } else if store.entries.isEmpty {
            showState(
                title: String(localized: "sessionIndex.empty.title", defaultValue: "Vault is empty"),
                subtitle: String(
                    localized: "sessionIndex.empty.subtitle",
                    defaultValue: "Claude Code, Codex, OpenCode, and Rovo Dev history will appear here."
                ),
                showsSpinner: false
            )
        } else {
            showTable()
            applyRows()
        }
    }

    private func showTable() {
        if tableContainer != nil { return }
        clearBody()
        let table = tableController.makeContainerView()
        table.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(table)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            table.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            table.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])
        tableContainer = table
    }

    private func showState(title: String, subtitle: String?, showsSpinner: Bool) {
        clearBody()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        if showsSpinner {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            stack.addArrangedSubview(spinner)
        }
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: showsSpinner ? 11 : 12)
        titleLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(titleLabel)
        if let subtitle {
            let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = .tertiaryLabelColor
            subtitleLabel.alignment = .center
            subtitleLabel.maximumNumberOfLines = 0
            stack.addArrangedSubview(subtitleLabel)
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        }
        bodyContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: bodyContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: bodyContainer.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: bodyContainer.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: bodyContainer.trailingAnchor, constant: -16),
        ])
    }

    private func clearBody() {
        if tableContainer != nil { tableController.dismantle() }
        tableContainer = nil
        bodyContainer.subviews.forEach { $0.removeFromSuperview() }
    }

    private func applyRows() {
        let sections = store.sectionsForCurrentGrouping()
        let draggedKey = dragCoordinator.draggedKey
        let gapActions = SectionGapActions(
            currentDraggedKey: { [weak dragCoordinator] in dragCoordinator?.draggedKey },
            moveSection: { [weak self] key, before in
                self?.store.moveSection(key, before: before)
            },
            clearDraggedKey: { [weak self] in
                self?.dragCoordinator.draggedKey = nil
                self?.applyRows()
            }
        )
        let search: SessionSearchFn = { [weak store] query, scope, offset, limit in
            guard let store else {
                return SessionIndexStore.SearchOutcome(entries: [], errors: [])
            }
            return await store.searchSessions(query: query, scope: scope, offset: offset, limit: limit)
        }
        let loadSnapshot: DirectorySnapshotFn = { [weak store] cwd in
            guard let store else { return DirectorySnapshot(cwd: cwd ?? "", entries: [], errors: []) }
            return await store.loadDirectorySnapshot(cwd: cwd)
        }
        let rows = sections.flatMap { section -> [SessionIndexTableRow] in
            let actions = IndexSectionActions(
                onBeginDrag: { [weak self] in
                    self?.dragCoordinator.draggedKey = section.key
                    self?.applyRows()
                },
                onPreviewEntry: { [weak self] entry in
                    self?.popoverIdentity = .transcript(section: section.key, entry: entry.id)
                    self?.applyRows()
                },
                onDismissPreview: { [weak self] entryID in
                    guard self?.popoverIdentity == .transcript(section: section.key, entry: entryID) else { return }
                    self?.popoverIdentity = nil
                    self?.applyRows()
                },
                onResume: onResume,
                search: search,
                loadSnapshot: loadSnapshot
            )
            return [
                .gap(
                    beforeKey: section.key,
                    isValidDrop: draggedKey == nil || draggedKey != section.key,
                    actions: gapActions
                ),
                .section(
                    section: section,
                    rowLimit: Self.collapsedRowLimit,
                    isDragged: draggedKey == section.key,
                    popoverIdentity: popoverIdentity?.sectionKey == section.key ? popoverIdentity : nil,
                    isCollapsed: collapsedSections.contains(section.key),
                    actions: actions,
                    setCollapsed: { [weak self] collapsed in
                        guard let self else { return }
                        if collapsed {
                            collapsedSections.insert(section.key)
                            if popoverIdentity?.sectionKey == section.key { popoverIdentity = nil }
                        } else {
                            collapsedSections.remove(section.key)
                        }
                        applyRows()
                    },
                    setPopoverOpen: { [weak self] open in
                        guard let self else { return }
                        if open {
                            popoverIdentity = .section(section.key)
                        } else if popoverIdentity == .section(section.key) {
                            popoverIdentity = nil
                        }
                        applyRows()
                    }
                ),
            ]
        } + [.gap(beforeKey: nil, isValidDrop: true, actions: gapActions)]

        let appearance = view.effectiveAppearance
        tableController.apply(
            rows: rows,
            environment: SessionIndexTableEnvironmentSnapshot(
                colorScheme: WindowChromeColorScheme(appearance: appearance),
                globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
            )
        )
    }

    private func installDragCancelMonitor() {
        guard dragCancelMonitor == nil else { return }
        dragCancelMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .otherMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self, self.dragCoordinator.draggedKey != nil else { return event }
            if event.type == .keyDown, event.keyCode != 53 { return event }
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.dragCoordinator.draggedKey = nil
                self?.applyRows()
            }
            return event
        }
    }

    @objc private func selectGrouping(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue.split(separator: ".").last.map(String.init),
              let grouping = SessionGrouping(rawValue: raw),
              store.grouping != grouping else { return }
        store.grouping = grouping
    }

    @objc private func toggleScope() {
        store.scopeToCurrentDirectory = scopeButton.state == .on
    }

    @objc private func reload() {
        store.reload()
    }
}

@MainActor
private final class SessionIndexNativeRootView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
