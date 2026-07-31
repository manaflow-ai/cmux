import AppKit
import Combine
import CmuxFoundation

/// Owns the complete History surface in AppKit. SwiftUI mounts this controller
/// as one opaque view and does not participate in filtering, refresh, layout,
/// or table updates.
@MainActor
final class VaultHistoryViewController: NSViewController {
    private let tabManager: TabManager
    private let sessionStore: SessionIndexStore
    private let closedItemStore: ClosedItemHistoryStore
    private let log: VaultHistoryEventLog
    private let defaults: UserDefaults
    private let model: VaultHistoryTimelineModel

    private var onResume: ((SessionEntry) -> Void)?
    private var onReopenClosedItem: ((UUID) -> Bool)?

    let controlsView = VaultHistoryControlsView()
    let tableController = VaultHistoryTableController()
    private lazy var tableContainer = tableController.makeContainerView()
    private let loadingView = VaultHistoryLoadingView()
    private let emptyView = VaultHistoryEmptyView()
    private let contentContainer = NSView()

    private var cancellables = Set<AnyCancellable>()
    private var refreshDebounceTask: Task<Void, Never>?
    private var isStarted = false

    private lazy var rowActions = VaultHistoryRowActions(
        onResume: { [weak self] entry in
            self?.onResume?(entry)
        },
        onReopenClosedItem: { [weak self] id in
            self?.onReopenClosedItem?(id) ?? false
        },
        onActivateWorkspace: { [weak self] workspaceId in
            self?.activateWorkspace(workspaceId) ?? false
        },
        onActivateTerminal: { [weak self] workspaceId, terminalId in
            self?.activateTerminal(workspaceId, terminalId) ?? false
        }
    )

    init(
        tabManager: TabManager,
        sessionStore: SessionIndexStore,
        closedItemStore: ClosedItemHistoryStore,
        log: VaultHistoryEventLog,
        onResume: ((SessionEntry) -> Void)?,
        onReopenClosedItem: ((UUID) -> Bool)?,
        defaults: UserDefaults = .standard
    ) {
        self.tabManager = tabManager
        self.sessionStore = sessionStore
        self.closedItemStore = closedItemStore
        self.log = log
        self.onResume = onResume
        self.onReopenClosedItem = onReopenClosedItem
        self.defaults = defaults
        let selectedMode = defaults.string(forKey: "vaultPane.tab")
            .flatMap(VaultHistoryMode.init(rawValue:)) ?? .timeline
        self.model = VaultHistoryTimelineModel(
            log: log,
            mode: selectedMode,
            defaults: defaults
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.translatesAutoresizingMaskIntoConstraints = false
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(controlsView)
        rootView.addSubview(contentContainer)
        for contentView in [tableContainer, loadingView, emptyView] {
            contentContainer.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            controlsView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            controlsView.topAnchor.constraint(equalTo: rootView.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: controlsView.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        view = rootView
        wireControls()
        model.onUpdate = { [weak self] update in
            guard let self else { return }
            switch update {
            case .loading:
                self.renderControls()
                if !self.model.didLoad {
                    self.show(.loading)
                }
            case .content:
                self.renderContent()
            }
        }
        emptyView.onClearFilters = { [weak self] in
            self?.model.clearFilters()
        }
        renderContent()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        loadViewIfNeeded()
        installObservers()
        if sessionStore.entries.isEmpty && !sessionStore.isLoading {
            sessionStore.reload()
        }
        refresh()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        model.cancelRefresh()
        cancellables.removeAll()
    }

    func updateCallbacks(
        onResume: ((SessionEntry) -> Void)?,
        onReopenClosedItem: ((UUID) -> Bool)?
    ) {
        self.onResume = onResume
        self.onReopenClosedItem = onReopenClosedItem
    }

    private func wireControls() {
        controlsView.onModeChange = { [weak self] mode in
            guard let self else { return }
            self.defaults.set(mode.rawValue, forKey: "vaultPane.tab")
            self.model.mode = mode
        }
        controlsView.onTimeRangeChange = { [weak self] range in
            self?.model.timeRange = range
        }
        controlsView.onSortOrderChange = { [weak self] order in
            self?.model.sortOrder = order
        }
        controlsView.onSearchChange = { [weak self] searchText in
            self?.model.searchText = searchText
        }
        controlsView.onReload = { [weak self] in
            guard let self else { return }
            self.sessionStore.reload()
            self.refresh()
        }
    }

    private func installObservers() {
        sessionStore.$entries
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
            .store(in: &cancellables)

        sessionStore.$isLoading
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.renderControls() }
            }
            .store(in: &cancellables)

        closedItemStore.$revision
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
            .store(in: &cancellables)

        tabManager.tabsPublisher
            .map { $0.map(\.id) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
            .store(in: &cancellables)

        let topologyNotifications: [Notification.Name] = [
            .vaultHistoryEventLogDidChange,
            .vaultHistoryLiveTopologyDidChange,
            .sharedLiveAgentIndexDidChange,
            .workspaceTitleDidChange,
            .workspaceCurrentDirectoryDidChange,
        ]
        for name in topologyNotifications {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.scheduleRefresh() }
                }
                .store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: GlobalFontMagnification.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.controlsView.applyFontMagnification()
                    self.loadingView.applyFontMagnification()
                    self.emptyView.applyFontMagnification()
                    self.renderContent()
                }
            }
            .store(in: &cancellables)
    }

    private func scheduleRefresh() {
        guard isStarted else { return }
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(75))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        let topology = VaultHistoryWorkspaceTopology.Snapshotter().capture(
            fallbackTabManager: tabManager,
            closedRecords: closedItemStore.recordsSnapshot
        )
        model.refresh(
            sessionEntries: sessionStore.entries,
            topology: topology
        )
    }

    private func renderControls() {
        guard isViewLoaded else { return }
        controlsView.update(
            mode: model.mode,
            timeRange: model.timeRange,
            sortOrder: model.sortOrder,
            searchText: model.searchText,
            isReloadDisabled: model.isLoading || sessionStore.isLoading
        )
    }

    private func renderContent() {
        guard isViewLoaded else { return }
        renderControls()
        guard model.didLoad else {
            show(.loading)
            return
        }

        let rows = model.workspaceSections.isEmpty
            ? VaultHistoryTimelineList.makeRows(
                groups: model.groups,
                resumeEntriesByEventId: model.resumeEntriesByEventId,
                availableClosedItemIds: closedItemStore.recordIdsSnapshot,
                actions: rowActions
            )
            : VaultHistoryTimelineList.makeWorkspaceRows(
                sections: model.workspaceSections,
                resumeEntriesByEventId: model.resumeEntriesByEventId,
                availableClosedItemIds: closedItemStore.recordIdsSnapshot,
                actions: rowActions
            )

        guard !rows.isEmpty else {
            emptyView.update(hasActiveFilters: model.hasActiveFilters)
            show(.empty)
            return
        }
        show(.table)
        tableController.apply(
            rows: rows,
            actions: rowActions,
            globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
        )
    }

    private enum ContentState {
        case loading
        case empty
        case table
    }

    private func show(_ state: ContentState) {
        loadingView.isHidden = state != .loading
        emptyView.isHidden = state != .empty
        tableContainer.isHidden = state != .table
    }

    @discardableResult
    private func activateWorkspace(_ workspaceId: UUID) -> Bool {
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) ?? (
            tabManager.workspacesById[workspaceId] == nil ? nil : tabManager
        ),
        let workspace = manager.workspacesById[workspaceId] else {
            return false
        }
        focusWindow(for: manager)
        manager.selectWorkspace(workspace)
        return true
    }

    @discardableResult
    private func activateTerminal(_ workspaceId: UUID, _ terminalId: UUID) -> Bool {
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) ?? (
            tabManager.workspacesById[workspaceId] == nil ? nil : tabManager
        ),
        let workspace = manager.workspacesById[workspaceId],
        workspace.panels[terminalId] != nil else {
            return false
        }
        focusWindow(for: manager)
        manager.selectWorkspace(workspace)
        workspace.focusPanel(terminalId)
        return true
    }

    private func focusWindow(for manager: TabManager) {
        guard let appDelegate = AppDelegate.shared,
              let windowId = appDelegate.windowId(for: manager) else {
            return
        }
        _ = appDelegate.focusScriptableMainWindow(
            windowId: windowId,
            bringToFront: true
        )
    }
}

@MainActor
private final class VaultHistoryLoadingView: NSView {
    private let progressIndicator = NSProgressIndicator()
    private let label = NSTextField(labelWithString: String(
        localized: "vaultHistory.loading",
        defaultValue: "Loading history…"
    ))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.startAnimation(nil)
        label.textColor = .secondaryLabelColor
        applyFontMagnification()

        let stack = NSStackView(views: [progressIndicator, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyFontMagnification() {
        label.font = GlobalFontMagnification.systemFont(ofSize: 11)
    }
}

@MainActor
private final class VaultHistoryEmptyView: NSView {
    var onClearFilters: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let clearButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 3
        applyFontMagnification()

        clearButton.title = String(
            localized: "vaultHistory.filters.clear",
            defaultValue: "Clear filters"
        )
        clearButton.isBordered = false
        clearButton.contentTintColor = .linkColor
        clearButton.target = self
        clearButton.action = #selector(clearFilters(_:))
        clearButton.setAccessibilityIdentifier("VaultHistoryClearFiltersButton")

        let stack = NSStackView(views: [titleLabel, subtitleLabel, clearButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyFontMagnification() {
        titleLabel.font = GlobalFontMagnification.systemFont(ofSize: 12)
        subtitleLabel.font = GlobalFontMagnification.systemFont(ofSize: 11)
    }

    func update(hasActiveFilters: Bool) {
        if hasActiveFilters {
            titleLabel.stringValue = String(
                localized: "vaultHistory.empty.filtered.title",
                defaultValue: "No matching history"
            )
            subtitleLabel.stringValue = String(
                localized: "vaultHistory.empty.filtered.subtitle",
                defaultValue: "Try another search or time range."
            )
        } else {
            titleLabel.stringValue = String(
                localized: "vaultHistory.empty.title",
                defaultValue: "No history yet"
            )
            subtitleLabel.stringValue = String(
                localized: "vaultHistory.empty.subtitle",
                defaultValue: "Workspace, window, and agent session activity will appear here."
            )
        }
        clearButton.isHidden = !hasActiveFilters
    }

    @objc private func clearFilters(_ sender: NSButton) {
        _ = sender
        onClearFilters?()
    }
}
