import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxFoundation
import Observation

#if DEBUG
private func feedDebugResponderSummary(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}
#endif

private enum FeedNativePanelFilter: String, CaseIterable {
    case actionable
    case activity

    var label: String {
        switch self {
        case .actionable:
            return String(localized: "feed.filter.actionable", defaultValue: "Actionable")
        case .activity:
            return String(localized: "feed.filter.activity", defaultValue: "All Activity")
        }
    }

    var symbolName: String {
        switch self {
        case .actionable: return "exclamationmark.circle"
        case .activity: return "checklist"
        }
    }
}

struct FeedNativeItemSnapshot: Equatable {
    let id: UUID
    let workstreamId: String
    let source: WorkstreamSource
    let kind: WorkstreamKind
    let title: String?
    let cwd: String?
    let createdAt: Date
    let status: WorkstreamStatus
    let payload: WorkstreamPayload
    let context: WorkstreamContext?
    let userPromptEcho: String?

    init(item: WorkstreamItem, userPromptEcho: String? = nil) {
        id = item.id
        workstreamId = item.workstreamId
        source = item.source
        kind = item.kind
        title = item.title
        cwd = item.cwd
        createdAt = item.createdAt
        status = item.status
        payload = item.payload
        context = item.context
        self.userPromptEcho = userPromptEcho
    }
}

struct FeedNativeRowActions {
    let approvePermission: (UUID, WorkstreamPermissionMode) -> Void
    let replyQuestion: (UUID, [String]) -> Void
    let approveExitPlan: (UUID, WorkstreamExitPlanMode, String?) -> Void
    let jump: (String) -> Void
    let sendText: (String, String) -> Void

    static func bound() -> Self {
        Self(
            approvePermission: { itemID, mode in
                Task { @MainActor in
                    FeedCoordinator.shared.deliverReply(
                        requestId: requestID(for: itemID) ?? itemID.uuidString,
                        decision: .permission(mode)
                    )
                }
            },
            replyQuestion: { itemID, selections in
                Task { @MainActor in
                    FeedCoordinator.shared.deliverReply(
                        requestId: requestID(for: itemID) ?? itemID.uuidString,
                        decision: .question(selections: selections)
                    )
                }
            },
            approveExitPlan: { itemID, mode, feedback in
                Task { @MainActor in
                    FeedCoordinator.shared.deliverReply(
                        requestId: requestID(for: itemID) ?? itemID.uuidString,
                        decision: .exitPlan(mode, feedback: feedback)
                    )
                }
            },
            jump: { workstreamID in
                Task { @MainActor in
                    _ = FeedCoordinator.shared.focusIfPossible(workstreamId: workstreamID)
                }
            },
            sendText: { workstreamID, value in
                Task { @MainActor in
                    FeedCoordinator.shared.sendTextToWorkstream(
                        workstreamId: workstreamID,
                        text: value
                    )
                }
            }
        )
    }

    @MainActor
    private static func requestID(for itemID: UUID) -> String? {
        FeedCoordinator.shared.store?.items.first(where: { $0.id == itemID }).flatMap { item in
            switch item.payload {
            case .permissionRequest(let requestID, _, _, _): return requestID
            case .exitPlan(let requestID, _, _): return requestID
            case .question(let requestID, _): return requestID
            default: return nil
            }
        }
    }
}

@MainActor
final class FeedNativeCardState {
    var stopReply = ""
    var exitPlanFeedback = ""
    var questionSelections: [String: Set<String>] = [:]
    var questionFreeText: [String: String] = [:]
    var showsAllCompletedTodos = false
}

enum FeedNativeButtonStyle: String, CaseIterable, Identifiable, Sendable {
    case ghost
    case soft
    case dark
    case light
    case primary
    case success
    case warning
    case destructive

    var id: String { rawValue }

    var debugLabel: String {
        switch self {
        case .ghost:
            String(localized: "feed.buttonDebug.kind.ghost", defaultValue: "Ghost")
        case .soft:
            String(localized: "feed.buttonDebug.kind.soft", defaultValue: "Soft")
        case .dark:
            String(localized: "feed.buttonDebug.kind.dark", defaultValue: "Dark")
        case .light:
            String(localized: "feed.buttonDebug.kind.light", defaultValue: "Light")
        case .primary:
            String(localized: "feed.buttonDebug.kind.primary", defaultValue: "Primary")
        case .success:
            String(localized: "feed.buttonDebug.kind.success", defaultValue: "Success")
        case .warning:
            String(localized: "feed.buttonDebug.kind.warning", defaultValue: "Warning")
        case .destructive:
            String(localized: "feed.buttonDebug.kind.destructive", defaultValue: "Destructive")
        }
    }
}

/// Hidden first-responder host used by the sidebar-wide keyboard focus coordinator.
@MainActor
final class FeedKeyboardFocusView: NSView {
    var onEscape: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onActivateSelection: (() -> Void)?
    var onFocusFirstItemRequested: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onFocusSnapshotChanged: ((FeedFocusSnapshot) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithKeyboardFocusCoordinatorIfNeeded()
#if DEBUG
        if let window {
            dlog("feed.focus.host attach window=\(ObjectIdentifier(window))")
        }
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFeedHost(self)
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
#if DEBUG
            dlog(
                "feed.focus.host escape window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil") " +
                    "fr=\(feedDebugResponderSummary(window?.firstResponder))"
            )
#endif
            onEscape?()
            return true
        }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            onMoveSelection?(delta)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
#if DEBUG
        let chars = event.charactersIgnoringModifiers ?? ""
        dlog(
            "feed.focus.host keyDown key=\(event.keyCode) chars=\(chars) " +
                "fr=\(feedDebugResponderSummary(window?.firstResponder))"
        )
#endif
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }

        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            onMoveSelection?(delta)
            return
        }

        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShortcutModifier = !normalizedFlags.intersection([.command, .control, .option]).isEmpty
        guard !hasShortcutModifier else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 36, 76:
            onActivateSelection?()
            return
        case 53:
            onEscape?()
            return
        default:
            break
        }

        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocusChanged?(true)
        }
#if DEBUG
        dlog(
            "feed.focus.host become result=\(result ? 1 : 0) " +
                "window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil") " +
                "fr=\(feedDebugResponderSummary(window?.firstResponder))"
        )
#endif
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            onFocusChanged?(false)
        }
#if DEBUG
        dlog(
            "feed.focus.host resign result=\(result ? 1 : 0) " +
                "window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil") " +
                "fr=\(feedDebugResponderSummary(window?.firstResponder))"
        )
#endif
        return result
    }

    func focusFirstItemFromCoordinator() {
        onFocusFirstItemRequested?()
    }

    func focusHostFromCoordinator() -> Bool {
        guard let window else { return false }
#if DEBUG
        let before = feedDebugResponderSummary(window.firstResponder)
#endif
        let result = window.makeFirstResponder(self)
#if DEBUG
        dlog(
            "feed.focus.host request result=\(result ? 1 : 0) " +
                "window=\(ObjectIdentifier(window)) before=\(before) " +
                "after=\(feedDebugResponderSummary(window.firstResponder))"
        )
#endif
        return result
    }

    func applyFocusSnapshotFromController(_ snapshot: FeedFocusSnapshot) {
        onFocusSnapshotChanged?(snapshot)
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        responder === self || responder is FeedKeyboardFocusResponder
    }
}

private enum FeedNativeListRow {
    case item(FeedNativeItemSnapshot, showsDivider: Bool)
    case historySeparator
    case loadMore(isLoading: Bool)

    var snapshot: FeedNativeItemSnapshot? {
        guard case .item(let snapshot, _) = self else { return nil }
        return snapshot
    }
}

/// AppKit owner for the Feed filter bar, keyboard routing, and native card list.
@MainActor
final class FeedPanelNativeViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("FeedNative.column")
    private static let cardIdentifier = NSUserInterfaceItemIdentifier("FeedNative.card")
    private static let separatorIdentifier = NSUserInterfaceItemIdentifier("FeedNative.separator")
    private static let loadMoreIdentifier = NSUserInterfaceItemIdentifier("FeedNative.loadMore")

    private let viewModel: FeedPanelViewModel
    private let actions: FeedNativeRowActions
    private let toolbar = NSStackView()
    private let bodyContainer = NSView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyStack = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptySubtitle = NSTextField(wrappingLabelWithString: "")
    private let focusView = FeedKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private let sizingCard = FeedNativeCardView()
    private var filterButtons: [FeedNativePanelFilter: NSButton] = [:]
    private var filter: FeedNativePanelFilter = .actionable
    private var rows: [FeedNativeListRow] = []
    private var visibleSnapshots: [FeedNativeItemSnapshot] = []
    private var states: [UUID: FeedNativeCardState] = [:]
    private var focusSnapshot = FeedFocusSnapshot()
    private var observationGeneration: UInt64 = 0

    init(
        viewModel: FeedPanelViewModel? = nil,
        actions: FeedNativeRowActions? = nil
    ) {
        self.viewModel = viewModel ?? FeedPanelViewModel()
        self.actions = actions ?? .bound()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.setAccessibilityIdentifier("FeedPanel")
        configureToolbar()
        configureTable()
        configureEmptyState()
        configureFocusView()

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(bodyContainer)
        root.addSubview(focusView)
        installRightSidebarChromeGeometryReporter(in: toolbar, role: .secondaryBar)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: RightSidebarChromeMetrics.barHorizontalPadding),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -RightSidebarChromeMetrics.barHorizontalPadding),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight),
            bodyContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            focusView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            focusView.topAnchor.constraint(equalTo: root.topAnchor),
            focusView.widthAnchor.constraint(equalToConstant: 1),
            focusView.heightAnchor.constraint(equalToConstant: 1),
        ])
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])
        view = root
        observeViewModel()
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func teardown() {
        observationGeneration &+= 1
        tableView.delegate = nil
        tableView.dataSource = nil
    }

    private func configureToolbar() {
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        toolbar.distribution = .fill
        for filter in FeedNativePanelFilter.allCases {
            let button = NSButton(title: filter.label, target: self, action: #selector(selectFilter(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("FeedNative.filter.\(filter.rawValue)")
            button.image = NSImage(systemSymbolName: filter.symbolName, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.toolTip = filter.label
            button.setAccessibilityLabel(filter.label)
            button.setAccessibilityIdentifier("rightSidebarSecondaryControl_feed_\(filter.rawValue)")
            installRightSidebarChromeGeometryReporter(
                in: button,
                role: .named("rightSidebarSecondaryControl_feed_\(filter.rawValue)")
            )
            filterButtons[filter] = button
            toolbar.addArrangedSubview(button)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)
    }

    private func configureTable() {
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = .zero
        tableView.rowHeight = 80
        tableView.dataSource = self
        tableView.delegate = self
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.applySidebarOverlayScrollerConfiguration()
        tableView.frame = scrollView.contentView.bounds
        tableView.autoresizingMask = [.width]
        bodyContainer.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])
    }

    private func configureEmptyState() {
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 4
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyTitle.font = .systemFont(ofSize: 12)
        emptyTitle.textColor = .secondaryLabelColor
        emptySubtitle.font = .systemFont(ofSize: 11)
        emptySubtitle.textColor = .tertiaryLabelColor
        emptySubtitle.alignment = .center
        emptySubtitle.maximumNumberOfLines = 0
        emptyStack.addArrangedSubview(emptyTitle)
        emptyStack.addArrangedSubview(emptySubtitle)
        bodyContainer.addSubview(emptyStack)
        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: bodyContainer.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: bodyContainer.centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: bodyContainer.leadingAnchor, constant: 16),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: bodyContainer.trailingAnchor, constant: -16),
            emptySubtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
    }

    private func configureFocusView() {
        focusView.translatesAutoresizingMaskIntoConstraints = false
        focusView.onEscape = { [weak self] in
            guard let self else { return }
            let window = activeWindow
            if AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() != true {
                window?.makeFirstResponder(nil)
            }
            syncFocusSnapshot()
        }
        focusView.onMoveSelection = { [weak self] delta in self?.moveSelection(delta: delta) }
        focusView.onActivateSelection = { [weak self] in self?.activateSelection() }
        focusView.onFocusFirstItemRequested = { [weak self] in self?.focusFirstVisibleItem() }
        focusView.onFocusChanged = { [weak self] focused in
            guard let self else { return }
            if !focused {
                AppDelegate.shared?.syncKeyboardFocusAfterFirstResponderChange(in: activeWindow)
            }
            syncFocusSnapshot()
        }
        focusView.onFocusSnapshotChanged = { [weak self] snapshot in
            self?.applyFocusSnapshot(snapshot)
        }
    }

    private func observeViewModel() {
        observationGeneration &+= 1
        observeViewModelChanges(generation: observationGeneration)
    }

    private func observeViewModelChanges(generation: UInt64) {
        withObservationTracking {
            _ = viewModel.items
            _ = viewModel.hasMorePersistedItems
            _ = viewModel.isLoadingOlderItems
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, observationGeneration == generation else { return }
                observeViewModelChanges(generation: generation)
                render()
            }
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        for (candidate, button) in filterButtons {
            let selected = candidate == filter
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        }

        let snapshots = makeVisibleSnapshots(from: viewModel.items)
        visibleSnapshots = snapshots
        rows = makeRows(from: snapshots)
        states = states.filter { id, _ in snapshots.contains(where: { $0.id == id }) }
        tableView.reloadData()
        emptyStack.isHidden = !snapshots.isEmpty || shouldShowHistoryLoader
        scrollView.isHidden = snapshots.isEmpty && !shouldShowHistoryLoader
        emptyTitle.stringValue = filter == .actionable
            ? String(localized: "feed.empty.actionable.title", defaultValue: "No pending decisions")
            : String(localized: "feed.empty.activity.title", defaultValue: "No activity yet")
        emptySubtitle.stringValue = filter == .actionable
            ? String(
                localized: "feed.empty.actionable.subtitle",
                defaultValue: "Permission, plan, and question requests from AI agents will appear here."
            )
            : String(
                localized: "feed.empty.activity.subtitle",
                defaultValue: "Agent decisions and todo-list updates will appear here."
            )
    }

    private func makeRows(from snapshots: [FeedNativeItemSnapshot]) -> [FeedNativeListRow] {
        guard filter == .activity else {
            return snapshots.enumerated().map { index, snapshot in
                .item(snapshot, showsDivider: index < snapshots.count - 1)
            }
        }
        let stable = snapshots.filter(prefersStableSurface)
        let history = snapshots.filter { !prefersStableSurface($0) }
        var result: [FeedNativeListRow] = stable.enumerated().map { index, snapshot in
            .item(snapshot, showsDivider: index < stable.count - 1)
        }
        if !stable.isEmpty, !history.isEmpty || viewModel.hasMorePersistedItems {
            result.append(.historySeparator)
        }
        result.append(contentsOf: history.enumerated().map { index, snapshot in
            .item(snapshot, showsDivider: index < history.count - 1)
        })
        if viewModel.hasMorePersistedItems {
            result.append(.loadMore(isLoading: viewModel.isLoadingOlderItems))
        }
        return result
    }

    private func makeVisibleSnapshots(from items: [WorkstreamItem]) -> [FeedNativeItemSnapshot] {
        var lastPromptByWorkstream: [String: String] = [:]
        for item in items {
            if case .userPrompt(let text) = item.payload, !text.isEmpty {
                lastPromptByWorkstream[item.workstreamId] = text
            }
        }
        let filtered: [WorkstreamItem]
        switch filter {
        case .actionable:
            filtered = items.filter { $0.kind.isActionable }
        case .activity:
            filtered = items.filter { item in
                item.kind.isActionable || item.kind == .todos || item.kind == .stop
            }
        }
        return filtered.reversed().map { item in
            FeedNativeItemSnapshot(
                item: item,
                userPromptEcho: lastPromptByWorkstream[item.workstreamId]
            )
        }
    }

    private func prefersStableSurface(_ snapshot: FeedNativeItemSnapshot) -> Bool {
        snapshot.status.isPending || snapshot.kind == .stop
    }

    private var shouldShowHistoryLoader: Bool {
        filter == .activity && viewModel.hasMorePersistedItems
    }

    private var activeWindow: NSWindow? {
        view.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func state(for id: UUID) -> FeedNativeCardState {
        if let state = states[id] { return state }
        let state = FeedNativeCardState()
        states[id] = state
        return state
    }

    private func selectRow(_ id: UUID, focusFeed: Bool) {
        let optimistic = FeedFocusSnapshot(selectedItemId: id, isKeyboardActive: true)
        focusSnapshot = optimistic
        if let controller = AppDelegate.shared?.keyboardFocusCoordinator(for: activeWindow) {
            _ = controller.selectFeedItem(id, focusFeed: focusFeed)
            focusSnapshot = controller.feedFocusSnapshot()
        }
        reloadSelectionPresentation()
    }

    private func focusFirstVisibleItem() {
        guard let id = preferredFocusItemID() else {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: .feed,
                focusFirstItem: false,
                preferredWindow: activeWindow
            )
            syncFocusSnapshot()
            return
        }
        selectRow(id, focusFeed: true)
        scrollToItem(id)
    }

    private func preferredFocusItemID() -> UUID? {
        let ids = visibleSnapshots.map(\.id)
        if let current = AppDelegate.shared?.keyboardFocusCoordinator(for: activeWindow)?
            .feedFocusSnapshot().selectedItemId,
           ids.contains(current) {
            return current
        }
        if let current = focusSnapshot.selectedItemId, ids.contains(current) {
            return current
        }
        return ids.first
    }

    private func moveSelection(delta: Int) {
        guard !visibleSnapshots.isEmpty else { return }
        let ids = visibleSnapshots.map(\.id)
        let targetIndex: Int
        if let selected = focusSnapshot.selectedItemId,
           let index = ids.firstIndex(of: selected) {
            targetIndex = min(max(index + delta, 0), ids.count - 1)
        } else {
            targetIndex = delta >= 0 ? 0 : ids.count - 1
        }
        let target = ids[targetIndex]
        selectRow(target, focusFeed: false)
        scrollToItem(target)
    }

    private func activateSelection() {
        guard let snapshot = focusSnapshot.selectedItemId.flatMap({ id in
            visibleSnapshots.first(where: { $0.id == id })
        }) ?? visibleSnapshots.first else { return }
        selectRow(snapshot.id, focusFeed: true)
        actions.jump(snapshot.workstreamId)
    }

    private func scrollToItem(_ id: UUID) {
        guard let row = rows.firstIndex(where: { $0.snapshot?.id == id }) else { return }
        tableView.scrollRowToVisible(row)
    }

    private func syncFocusSnapshot() {
        guard let controller = AppDelegate.shared?.keyboardFocusCoordinator(for: activeWindow) else { return }
        applyFocusSnapshot(controller.feedFocusSnapshot())
    }

    private func applyFocusSnapshot(_ snapshot: FeedFocusSnapshot) {
        guard snapshot != focusSnapshot else { return }
        focusSnapshot = snapshot
        reloadSelectionPresentation()
    }

    private func reloadSelectionPresentation() {
        let indexes = IndexSet(rows.indices.filter { rows[$0].snapshot != nil })
        guard !indexes.isEmpty else { return }
        tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
    }

    private func reloadItem(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.snapshot?.id == id }) else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
    }

    @objc private func selectFilter(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue.split(separator: ".").last.map(String.init),
              let next = FeedNativePanelFilter(rawValue: raw),
              next != filter else { return }
        filter = next
        render()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .item(let snapshot, let showsDivider):
            let cell = (tableView.makeView(withIdentifier: Self.cardIdentifier, owner: self)
                as? FeedNativeTableCellView) ?? FeedNativeTableCellView()
            cell.identifier = Self.cardIdentifier
            cell.configure(
                snapshot: snapshot,
                state: state(for: snapshot.id),
                actions: actions,
                isSelected: focusSnapshot.selectedItemId == snapshot.id,
                isKeyboardActive: focusSnapshot.isKeyboardActive,
                showsDivider: showsDivider,
                onSelect: { [weak self] focus in self?.selectRow(snapshot.id, focusFeed: focus) },
                onActivate: { [weak self] in
                    self?.selectRow(snapshot.id, focusFeed: true)
                    self?.actions.jump(snapshot.workstreamId)
                },
                onStateChange: { [weak self] in self?.reloadItem(snapshot.id) }
            )
            return cell
        case .historySeparator:
            let view = (tableView.makeView(withIdentifier: Self.separatorIdentifier, owner: self)
                as? FeedNativeHistorySeparatorView) ?? FeedNativeHistorySeparatorView()
            view.identifier = Self.separatorIdentifier
            return view
        case .loadMore(let isLoading):
            let view = (tableView.makeView(withIdentifier: Self.loadMoreIdentifier, owner: self)
                as? FeedNativeLoadMoreView) ?? FeedNativeLoadMoreView()
            view.identifier = Self.loadMoreIdentifier
            view.configure(isLoading: isLoading) { [weak self] in self?.viewModel.loadOlderItems() }
            return view
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return tableView.rowHeight }
        switch rows[row] {
        case .historySeparator:
            return 18
        case .loadMore:
            return 40
        case .item(let snapshot, let showsDivider):
            let width = max(240, tableView.bounds.width)
            sizingCard.configure(
                snapshot: snapshot,
                state: state(for: snapshot.id),
                actions: actions,
                isSelected: false,
                isKeyboardActive: false,
                showsDivider: showsDivider,
                onSelect: { _ in },
                onActivate: {},
                onStateChange: {}
            )
            return sizingCard.height(fittingWidth: width)
        }
    }
}

@MainActor
private final class FeedNativeTableCellView: NSTableCellView {
    private let card = FeedNativeCardView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        snapshot: FeedNativeItemSnapshot,
        state: FeedNativeCardState,
        actions: FeedNativeRowActions,
        isSelected: Bool,
        isKeyboardActive: Bool,
        showsDivider: Bool,
        onSelect: @escaping (Bool) -> Void,
        onActivate: @escaping () -> Void,
        onStateChange: @escaping () -> Void
    ) {
        card.configure(
            snapshot: snapshot,
            state: state,
            actions: actions,
            isSelected: isSelected,
            isKeyboardActive: isKeyboardActive,
            showsDivider: showsDivider,
            onSelect: onSelect,
            onActivate: onActivate,
            onStateChange: onStateChange
        )
    }
}

@MainActor
private final class FeedNativeHistorySeparatorView: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let left = NSBox()
        let right = NSBox()
        left.boxType = .separator
        right.boxType = .separator
        let label = NSTextField(
            labelWithString: String(localized: "feed.divider.resolved", defaultValue: "Resolved")
        )
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [left, label, right])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class FeedNativeLoadMoreView: NSTableCellView {
    private let button = FeedNativeActionButton()
    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        let stack = NSStackView(views: [spinner, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(isLoading: Bool, action: @escaping () -> Void) {
        spinner.isHidden = !isLoading
        if isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        button.title = isLoading
            ? String(localized: "feed.history.loadingOlder", defaultValue: "Loading older activity...")
            : String(localized: "feed.history.loadOlder", defaultValue: "Load older activity")
        button.isEnabled = !isLoading
        button.onAction = action
    }
}

@MainActor
final class FeedNativeCardView: NSView {
    private static let customAnswerSelectionID = "__cmux_custom_answer__"
    private static let skipInterviewAnswer = "Skip interview and plan immediately"
    private let contentStack = NSStackView()
    private let divider = NSBox()
    private var dividerHeight: NSLayoutConstraint!
    private var trackingAreaReference: NSTrackingArea?
    private var snapshot: FeedNativeItemSnapshot?
    private var state: FeedNativeCardState?
    private var actions: FeedNativeRowActions?
    private var onSelect: ((Bool) -> Void)?
    private var onActivate: (() -> Void)?
    private var onStateChange: (() -> Void)?
    private var isSelected = false
    private var isKeyboardActive = false
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        addSubview(divider)
        dividerHeight = divider.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            contentStack.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -10),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        snapshot: FeedNativeItemSnapshot,
        state: FeedNativeCardState,
        actions: FeedNativeRowActions,
        isSelected: Bool,
        isKeyboardActive: Bool,
        showsDivider: Bool,
        onSelect: @escaping (Bool) -> Void,
        onActivate: @escaping () -> Void,
        onStateChange: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.state = state
        self.actions = actions
        self.isSelected = isSelected
        self.isKeyboardActive = isKeyboardActive
        self.onSelect = onSelect
        self.onActivate = onActivate
        self.onStateChange = onStateChange
        dividerHeight.constant = showsDivider ? 1 : 0
        divider.isHidden = !showsDivider
        alphaValue = snapshot.isResolvedOrExpired ? 0.6 : 1
        toolTip = snapshot.helpText
        rebuild()
        updateBackground()
    }

    func height(fittingWidth width: CGFloat) -> CGFloat {
        let widthConstraint = widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        layoutSubtreeIfNeeded()
        let height = max(44, ceil(fittingSize.height))
        widthConstraint.isActive = false
        return height
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingAreaReference = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(false)
        if event.clickCount == 2 { onActivate?() }
    }

    private func rebuild() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let snapshot else { return }
        addFullWidth(header(for: snapshot))
        if let context = snapshot.displayContext {
            addFullWidth(contextView(context, source: snapshot.source))
        } else if let echo = snapshot.promptEcho {
            addFullWidth(wrappingLabel(echo, size: 11, color: .secondaryLabelColor, maximumLines: 2))
        }
        addFullWidth(actionView(for: snapshot))
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func addFullWidth(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func header(for snapshot: FeedNativeItemSnapshot) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: snapshot.kind.feedSymbolName, accessibilityDescription: nil)
        icon.contentTintColor = snapshot.kind.feedTint(status: snapshot.status)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let title = NSTextField(labelWithString: snapshot.headerTitle)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .labelColor.withAlphaComponent(0.92)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let source = FeedNativeBadgeView(
            text: snapshot.source.rawValue.capitalized,
            foreground: snapshot.source.feedForeground,
            background: snapshot.source.feedForeground.withAlphaComponent(0.18),
            monospacedDigits: false
        )
        let age = FeedNativeBadgeView(
            text: snapshot.relativeTimeChip,
            foreground: .secondaryLabelColor,
            background: .labelColor.withAlphaComponent(0.10),
            monospacedDigits: true
        )
        let stack = NSStackView(views: [icon, title, source, age])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func contextView(_ context: WorkstreamContext, source: WorkstreamSource) -> NSView {
        let stack = verticalStack(spacing: 4)
        if let user = context.lastUserMessage {
            addLabeledText(
                to: stack,
                label: String(localized: "feed.context.you", defaultValue: "You:"),
                text: user,
                labelColor: .secondaryLabelColor
            )
        }
        if let preamble = context.assistantPreamble {
            addLabeledText(
                to: stack,
                label: "\(source.rawValue.capitalized):",
                text: preamble,
                labelColor: .secondaryLabelColor
            )
        }
        if let plan = context.planSummary {
            addLabeledText(
                to: stack,
                label: String(localized: "feed.context.plan", defaultValue: "Plan:"),
                text: plan,
                labelColor: .systemPurple
            )
        }
        return stack
    }

    private func addLabeledText(
        to stack: NSStackView,
        label: String,
        text: String,
        labelColor: NSColor
    ) {
        let prefix = NSTextField(labelWithString: label)
        prefix.font = .systemFont(ofSize: 10, weight: .semibold)
        prefix.textColor = labelColor
        prefix.alignment = .left
        prefix.translatesAutoresizingMaskIntoConstraints = false
        prefix.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let body = wrappingLabel(text, size: 11, color: .secondaryLabelColor)
        let row = NSStackView(views: [prefix, body])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func actionView(for snapshot: FeedNativeItemSnapshot) -> NSView {
        switch snapshot.payload {
        case .permissionRequest(_, let toolName, let input, _):
            return permissionView(snapshot: snapshot, toolName: toolName, input: input)
        case .exitPlan(_, let plan, _):
            return exitPlanView(snapshot: snapshot, plan: plan)
        case .question(_, let questions):
            return questionView(snapshot: snapshot, questions: questions)
        case .stop:
            return stopView(snapshot: snapshot)
        default:
            return telemetryView(snapshot: snapshot)
        }
    }

    private func permissionView(
        snapshot: FeedNativeItemSnapshot,
        toolName: String,
        input: String
    ) -> NSView {
        let stack = verticalStack(spacing: 10)
        stack.addArrangedSubview(iconTextView(
            systemName: "exclamationmark.triangle.fill",
            text: toolName,
            size: 11,
            color: .systemOrange,
            weight: .semibold
        ))

        let preview = FeedNativePermissionInputPreview(toolName: toolName, toolInputJSON: input)
        let previewStack = verticalStack(spacing: 6)
        if let primary = preview.primary {
            let text = [preview.sigil, primary].compactMap { $0 }.joined(separator: " ")
            previewStack.addArrangedSubview(
                wrappingLabel(text, size: 11, color: .labelColor, monospaced: true)
            )
        }
        if let secondary = preview.secondary, !secondary.isEmpty {
            previewStack.addArrangedSubview(
                wrappingLabel(secondary, size: 10, color: .secondaryLabelColor)
            )
        }
        stack.addArrangedSubview(FeedNativeBoxView(content: previewStack, tint: .labelColor))

        if snapshot.status.isPending {
            var buttons: [NSButton] = [permissionButton(
                title: String(localized: "feed.permission.deny", defaultValue: "Deny"),
                identifier: "FeedPermissionDenyButton",
                style: .dark,
                snapshot: snapshot,
                mode: .deny
            )]
            if FeedPermissionActionPolicy.supportsOncePermissionMode(source: snapshot.source, toolInputJSON: input) {
                buttons.append(permissionButton(
                    title: String(localized: "feed.permission.once", defaultValue: "Allow Once"),
                    identifier: "FeedPermissionAllowOnceButton",
                    style: .light,
                    snapshot: snapshot,
                    mode: .once
                ))
            }
            if FeedPermissionActionPolicy.supportsAlwaysPermissionMode(source: snapshot.source, toolInputJSON: input) {
                buttons.append(permissionButton(
                    title: String(localized: "feed.permission.always", defaultValue: "Always Allow"),
                    identifier: "FeedPermissionAlwaysAllowButton",
                    style: .primary,
                    snapshot: snapshot,
                    mode: .always
                ))
            }
            if FeedPermissionActionPolicy.supportsAllPermissionMode(source: snapshot.source, toolInputJSON: input) {
                buttons.append(permissionButton(
                    title: String(localized: "feed.permission.all", defaultValue: "All tools"),
                    identifier: "FeedPermissionAllToolsButton",
                    style: .primary,
                    snapshot: snapshot,
                    mode: .all
                ))
            }
            if FeedPermissionActionPolicy.supportsBypassPermissions(source: snapshot.source) {
                buttons.append(permissionButton(
                    title: String(localized: "feed.permission.bypass", defaultValue: "Bypass"),
                    identifier: "FeedPermissionBypassButton",
                    style: .destructive,
                    snapshot: snapshot,
                    mode: .bypass
                ))
            }
            stack.addArrangedSubview(buttonRow(buttons))
        } else if let badge = snapshot.resolvedBadgeLabel {
            stack.addArrangedSubview(statusButton(badge))
        }
        return stack
    }

    private func permissionButton(
        title: String,
        identifier: String,
        style: FeedNativeButtonStyle,
        snapshot: FeedNativeItemSnapshot,
        mode: WorkstreamPermissionMode
    ) -> NSButton {
        let button = actionButton(title: title, style: style) { [weak self] in
            self?.onSelect?(true)
            self?.actions?.approvePermission(snapshot.id, mode)
        }
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    private func exitPlanView(snapshot: FeedNativeItemSnapshot, plan: String) -> NSView {
        let stack = verticalStack(spacing: 10)
        let preview = WorkstreamExitPlanPreview(rawPlan: plan)
        stack.addArrangedSubview(wrappingLabel(preview.planText, size: 11, color: .labelColor))
        if !preview.allowedPrompts.isEmpty {
            let promptStack = verticalStack(spacing: 5)
            let title = NSTextField(
                labelWithString: String(localized: "feed.exitplan.allowedPrompts", defaultValue: "Allowed prompts")
            )
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = .systemPurple
            promptStack.addArrangedSubview(title)
            for prompt in preview.allowedPrompts {
                let value = prompt.tool.isEmpty ? prompt.prompt : "\(prompt.tool) · \(prompt.prompt)"
                promptStack.addArrangedSubview(wrappingLabel(value, size: 11, color: .labelColor))
            }
            stack.addArrangedSubview(FeedNativeBoxView(content: promptStack, tint: .systemPurple))
        }
        if let path = preview.planFilePath {
            let file = NSTextField(labelWithString: [
                String(localized: "feed.exitplan.planFile", defaultValue: "Plan file"),
                (path as NSString).lastPathComponent,
            ].joined(separator: " · "))
            file.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            file.textColor = .secondaryLabelColor
            file.toolTip = path
            stack.addArrangedSubview(file)
        }

        guard snapshot.status.isPending, let state else {
            if let badge = snapshot.resolvedBadgeLabel { stack.addArrangedSubview(statusButton(badge)) }
            return stack
        }

        let editor = FeedNativeTextField()
        editor.placeholderString = String(
            localized: "feed.exitplan.feedback.placeholder",
            defaultValue: "Tell Claude what to change…"
        )
        editor.stringValue = state.exitPlanFeedback
        editor.maximumNumberOfLines = 3
        editor.lineBreakMode = .byWordWrapping
        editor.font = .systemFont(ofSize: 12)
        editor.onBeginEditing = { [weak self] in self?.onSelect?(false) }

        let primary = actionButton(title: "", style: .soft, action: {})
        let manual = actionButton(
            title: String(localized: "feed.exitplan.manual", defaultValue: "Manual"),
            style: .soft,
            action: {}
        )
        let automatic = actionButton(
            title: String(localized: "feed.exitplan.auto", defaultValue: "Auto"),
            style: .success,
            action: {}
        )
        let updateButtons = { [weak state, weak primary, weak manual, weak automatic] in
            guard let state else { return }
            let feedback = state.exitPlanFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasFeedback = !feedback.isEmpty
            primary?.title = hasFeedback
                ? String(localized: "feed.exitplan.refine", defaultValue: "Send feedback")
                : String(localized: "feed.exitplan.ultraplan", defaultValue: "Ultraplan")
            primary?.style = hasFeedback ? .primary : .soft
            manual?.isEnabled = !hasFeedback
            automatic?.isEnabled = !hasFeedback
        }
        editor.onTextChange = { [weak state] value in
            state?.exitPlanFeedback = value
            updateButtons()
        }
        primary.onAction = { [weak self, weak state] in
            guard let self, let state else { return }
            let feedback = state.exitPlanFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
            onSelect?(true)
            actions?.approveExitPlan(
                snapshot.id,
                feedback.isEmpty ? .ultraplan : .manual,
                feedback.isEmpty ? nil : feedback
            )
        }
        manual.onAction = { [weak self, weak state] in
            guard let self, let state else { return }
            let feedback = state.exitPlanFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
            onSelect?(true)
            actions?.approveExitPlan(snapshot.id, .manual, feedback.isEmpty ? nil : feedback)
        }
        automatic.onAction = { [weak self, weak state] in
            guard let self, let state else { return }
            let feedback = state.exitPlanFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
            onSelect?(true)
            actions?.approveExitPlan(snapshot.id, .autoAccept, feedback.isEmpty ? nil : feedback)
        }
        updateButtons()
        stack.addArrangedSubview(editor)
        stack.addArrangedSubview(buttonRow([primary, manual, automatic]))
        return stack
    }

    private func questionView(
        snapshot: FeedNativeItemSnapshot,
        questions: [WorkstreamQuestionPrompt]
    ) -> NSView {
        let stack = verticalStack(spacing: 12)
        guard let state else { return stack }
        for (index, question) in questions.enumerated() {
            let questionStack = verticalStack(spacing: 6)
            if let header = question.header, !header.isEmpty {
                let headerLabel = NSTextField(labelWithString: header)
                headerLabel.font = .systemFont(ofSize: 10, weight: .semibold)
                headerLabel.textColor = .systemBlue
                questionStack.addArrangedSubview(headerLabel)
            }
            let promptPrefix = questions.count > 1 ? "\(index + 1). " : ""
            questionStack.addArrangedSubview(
                wrappingLabel(promptPrefix + question.prompt, size: 11, color: .labelColor, weight: .medium)
            )
            if question.multiSelect {
                let multi = NSTextField(
                    labelWithString: String(localized: "feed.question.multiSelect", defaultValue: "Multi-select")
                )
                multi.font = .systemFont(ofSize: 9, weight: .semibold)
                multi.textColor = .systemOrange
                questionStack.addArrangedSubview(multi)
            }
            if question.options.isEmpty {
                questionStack.addArrangedSubview(wrappingLabel(
                    String(localized: "feed.question.noOptions", defaultValue: "Agent provided no options."),
                    size: 10,
                    color: .secondaryLabelColor
                ))
            } else {
                for option in question.options {
                    questionStack.addArrangedSubview(
                        questionOptionView(
                            snapshot: snapshot,
                            question: question,
                            option: option,
                            state: state
                        )
                    )
                }
            }
            if snapshot.status.isPending {
                let custom = FeedNativeTextField()
                custom.placeholderString = String(
                    localized: "feed.question.typeSomething",
                    defaultValue: "Type something..."
                )
                custom.font = .systemFont(ofSize: 11)
                custom.stringValue = state.questionFreeText[question.id] ?? ""
                custom.onBeginEditing = { [weak self] in self?.onSelect?(false) }
                custom.onTextChange = { [weak self, weak state] value in
                    guard let self, let state else { return }
                    state.questionFreeText[question.id] = value
                    var selection = state.questionSelections[question.id] ?? []
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        selection.remove(Self.customAnswerSelectionID)
                    } else if question.multiSelect {
                        selection.insert(Self.customAnswerSelectionID)
                    } else {
                        selection = [Self.customAnswerSelectionID]
                    }
                    state.questionSelections[question.id] = selection
                }
                questionStack.addArrangedSubview(custom)
            }
            stack.addArrangedSubview(FeedNativeBoxView(content: questionStack, tint: .systemBlue))
        }

        if snapshot.status.isPending {
            let submit = actionButton(
                title: String(localized: "feed.question.submitAll", defaultValue: "Submit All Answers"),
                symbol: "checkmark.circle.fill",
                style: .primary
            ) { [weak self, weak state] in
                guard let self, let state else { return }
                let answers = composedAnswers(questions: questions, state: state)
                guard !answers.isEmpty || questions.allSatisfy({ $0.options.isEmpty }) else { return }
                onSelect?(true)
                actions?.replyQuestion(snapshot.id, answers)
            }
            if isPlanInterview(snapshot: snapshot, questions: questions) {
                let skip = actionButton(
                    title: String(localized: "feed.question.skipInterviewPlan", defaultValue: "Skip + plan immediately"),
                    symbol: "forward.end.fill",
                    style: .soft
                ) { [weak self] in
                    self?.onSelect?(true)
                    self?.actions?.replyQuestion(snapshot.id, [Self.skipInterviewAnswer])
                }
                stack.addArrangedSubview(buttonRow([skip, submit]))
            } else {
                stack.addArrangedSubview(buttonRow([submit]))
            }
        } else {
            stack.addArrangedSubview(statusButton(
                String(localized: "feed.badge.submitted", defaultValue: "Submitted")
            ))
        }
        return stack
    }

    private func questionOptionView(
        snapshot: FeedNativeItemSnapshot,
        question: WorkstreamQuestionPrompt,
        option: WorkstreamQuestionOption,
        state: FeedNativeCardState
    ) -> NSView {
        let selected = state.questionSelections[question.id]?.contains(option.id) == true
        let button = actionButton(
            title: option.label,
            symbol: question.multiSelect
                ? (selected ? "checkmark.square.fill" : "square")
                : (selected ? "checkmark.circle.fill" : "circle"),
            style: selected ? (question.multiSelect ? .success : .primary) : .soft
        ) { [weak self, weak state] in
            guard let self, let state, snapshot.status.isPending else { return }
            onSelect?(true)
            var current = state.questionSelections[question.id] ?? []
            if question.multiSelect {
                if current.contains(option.id) {
                    current.remove(option.id)
                } else {
                    current.insert(option.id)
                }
            } else {
                current = [option.id]
            }
            state.questionSelections[question.id] = current
            onStateChange?()
        }
        button.isEnabled = snapshot.status.isPending
        guard let description = option.description, !description.isEmpty else { return button }
        let stack = verticalStack(spacing: 3)
        stack.addArrangedSubview(button)
        let detail = wrappingLabel(description, size: 11, color: .secondaryLabelColor)
        detail.alignment = .left
        stack.addArrangedSubview(detail)
        return stack
    }

    private func composedAnswers(
        questions: [WorkstreamQuestionPrompt],
        state: FeedNativeCardState
    ) -> [String] {
        var answers: [String] = []
        for question in questions {
            let freeText = (state.questionFreeText[question.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = state.questionSelections[question.id] ?? []
            if !freeText.isEmpty, ids.contains(Self.customAnswerSelectionID) {
                answers.append(freeText)
                continue
            }
            let labels = question.options.filter { ids.contains($0.id) }.map(\.label)
            if !labels.isEmpty { answers.append(labels.joined(separator: ", ")) }
        }
        return answers
    }

    private func isPlanInterview(
        snapshot: FeedNativeItemSnapshot,
        questions: [WorkstreamQuestionPrompt]
    ) -> Bool {
        guard snapshot.source == .claude else { return false }
        if snapshot.context?.permissionMode?.caseInsensitiveCompare("plan") == .orderedSame {
            return true
        }
        let fragments = questions.flatMap { question -> [String] in
            [question.header, question.prompt]
                .compactMap { $0 }
                + question.options.flatMap { [$0.label, $0.description].compactMap { $0 } }
        }
        let text = ([snapshot.context?.lastUserMessage, snapshot.context?.assistantPreamble]
            .compactMap { $0 } + fragments).joined(separator: " ").lowercased()
        return text.contains("plan mode")
            || text.contains("make a plan")
            || text.contains("plan-only")
            || text.contains("plan immediately")
    }

    private func stopView(snapshot: FeedNativeItemSnapshot) -> NSView {
        let stack = verticalStack(spacing: 8)
        stack.addArrangedSubview(iconTextView(
            systemName: "checkmark.circle",
            text: String(
                localized: "feed.stop.label",
                defaultValue: "Claude finished — reply to continue"
            ),
            size: 11,
            color: .secondaryLabelColor,
            weight: .medium
        ))
        guard let state else { return stack }
        let field = FeedNativeTextField()
        field.placeholderString = String(localized: "feed.stop.placeholder", defaultValue: "Reply to Claude…")
        field.font = .systemFont(ofSize: 12)
        field.stringValue = state.stopReply
        field.onBeginEditing = { [weak self] in self?.onSelect?(false) }
        let send = actionButton(
            title: String(localized: "feed.stop.send", defaultValue: "Send to Claude"),
            symbol: "arrow.up.circle.fill",
            style: .primary,
            action: {}
        )
        let performSend = { [weak self, weak state, weak field, weak send] in
            guard let self, let state else { return }
            let value = state.stopReply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            onSelect?(true)
            actions?.sendText(snapshot.workstreamId, value)
            state.stopReply = ""
            field?.stringValue = ""
            send?.isEnabled = false
        }
        send.onAction = performSend
        field.onSubmit = performSend
        field.onTextChange = { [weak state, weak send] value in
            state?.stopReply = value
            send?.isEnabled = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        send.isEnabled = !state.stopReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(buttonRow([send]))
        return stack
    }

    private func telemetryView(snapshot: FeedNativeItemSnapshot) -> NSView {
        switch snapshot.payload {
        case .todos(let todos):
            return todosView(todos)
        case .assistantMessage(let text) where snapshot.source == .claude:
            return wrappingLabel(text, size: 11, color: .secondaryLabelColor, maximumLines: 3)
        default:
            return wrappingLabel(
                snapshot.telemetrySummary,
                size: 11,
                color: .secondaryLabelColor,
                monospaced: true,
                maximumLines: 3
            )
        }
    }

    private func todosView(_ todos: [WorkstreamTaskTodo]) -> NSView {
        let stack = verticalStack(spacing: 5)
        let done = todos.filter { $0.state == .completed }
        let inProgress = todos.filter { $0.state == .inProgress }
        let pending = todos.filter { $0.state == .pending }
        let title = NSTextField(labelWithString: [
            String(localized: "feed.todos.title", defaultValue: "Tasks"),
            "(\(todoSummary(done: done.count, inProgress: inProgress.count, pending: pending.count)))",
        ].joined(separator: " "))
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        stack.addArrangedSubview(title)
        let visibleDone = state?.showsAllCompletedTodos == true ? done : Array(done.prefix(2))
        for todo in inProgress + pending + visibleDone {
            stack.addArrangedSubview(iconTextView(
                systemName: todo.state.feedSymbolName,
                text: todo.content,
                size: 12,
                color: todo.state == .completed ? .tertiaryLabelColor : .labelColor,
                weight: .regular
            ))
        }
        if done.count > visibleDone.count {
            let button = actionButton(
                title: String(
                    localized: "feed.todos.moreCompleted",
                    defaultValue: "... +\(done.count - visibleDone.count) completed"
                ),
                style: .ghost
            ) { [weak self] in
                self?.state?.showsAllCompletedTodos = true
                self?.onStateChange?()
            }
            stack.addArrangedSubview(button)
        } else if state?.showsAllCompletedTodos == true, done.count > 2 {
            let button = actionButton(
                title: String(localized: "feed.todos.collapse", defaultValue: "Collapse"),
                style: .ghost
            ) { [weak self] in
                self?.state?.showsAllCompletedTodos = false
                self?.onStateChange?()
            }
            stack.addArrangedSubview(button)
        }
        return stack
    }

    private func todoSummary(done: Int, inProgress: Int, pending: Int) -> String {
        var parts: [String] = []
        if done > 0 {
            parts.append(String(localized: "feed.todos.summary.done", defaultValue: "\(done) done"))
        }
        if inProgress > 0 {
            parts.append(String(localized: "feed.todos.summary.inProgress", defaultValue: "\(inProgress) in progress"))
        }
        if pending > 0 {
            parts.append(String(localized: "feed.todos.summary.open", defaultValue: "\(pending) open"))
        }
        return parts.joined(separator: ", ")
    }

    private func statusButton(_ title: String) -> NSButton {
        let button = actionButton(title: title, symbol: "checkmark", style: .success, action: {})
        button.isEnabled = false
        return button
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.distribution = .fillEqually
        return stack
    }

    private func actionButton(
        title: String,
        symbol: String? = nil,
        style: FeedNativeButtonStyle,
        action: @escaping () -> Void
    ) -> FeedNativeActionButton {
        let button = FeedNativeActionButton()
        button.title = title
        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        button.imagePosition = symbol == nil ? .noImage : .imageLeading
        button.style = style
        button.onAction = action
        button.toolTip = title
        return button
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.distribution = .fill
        return stack
    }

    private func iconTextView(
        systemName: String,
        text: String,
        size: CGFloat,
        color: NSColor,
        weight: NSFont.Weight
    ) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        icon.contentTintColor = color
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: max(9, size - 1), weight: weight)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let label = wrappingLabel(text, size: size, color: color, weight: weight)
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 6
        return row
    }

    private func wrappingLabel(
        _ text: String,
        size: CGFloat,
        color: NSColor,
        weight: NSFont.Weight = .regular,
        monospaced: Bool = false,
        maximumLines: Int = 0
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = monospaced
            ? .monospacedSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = maximumLines
        label.lineBreakMode = maximumLines == 1 ? .byTruncatingTail : .byWordWrapping
        label.isSelectable = true
        return label
    }

    private func updateBackground() {
        guard let snapshot else {
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        let color: NSColor
        if isSelected {
            if isKeyboardActive, snapshot.status.isPending {
                color = snapshot.kind.feedTint(status: snapshot.status).withAlphaComponent(0.14)
            } else {
                color = .labelColor.withAlphaComponent(0.075)
            }
        } else if hovering {
            color = snapshot.status.isPending
                ? snapshot.kind.feedTint(status: snapshot.status).withAlphaComponent(0.10)
                : .labelColor.withAlphaComponent(0.055)
        } else {
            color = .clear
        }
        layer?.backgroundColor = color.cgColor
    }
}

@MainActor
final class FeedNativeActionButton: NSButton {
    var onAction: (() -> Void)?
    var style: FeedNativeButtonStyle = .soft { didSet { applyStyle() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(performAction)
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 10.5, weight: .semibold)
        imageHugsTitle = true
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyStyle() {
        wantsLayer = true
        layer?.cornerRadius = 6
        switch style {
        case .ghost:
            isBordered = false
            contentTintColor = .secondaryLabelColor
            layer?.backgroundColor = NSColor.clear.cgColor
        case .soft:
            isBordered = true
            contentTintColor = .labelColor
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        case .dark:
            isBordered = false
            contentTintColor = .white
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        case .light:
            isBordered = false
            contentTintColor = .black
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.90).cgColor
        case .primary:
            isBordered = false
            contentTintColor = .white
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.92).cgColor
        case .success:
            isBordered = false
            contentTintColor = .white
            layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.88).cgColor
        case .warning:
            isBordered = false
            contentTintColor = .white
            layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.90).cgColor
        case .destructive:
            isBordered = false
            contentTintColor = .white
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.88).cgColor
        }
    }

    @objc private func performAction() {
        guard isEnabled else { return }
        onAction?()
    }
}

@MainActor
private final class FeedNativeTextField: NSTextField, NSTextFieldDelegate, FeedKeyboardFocusResponder {
    var onTextChange: ((String) -> Void)?
    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var onSubmit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        bezelStyle = .roundedBezel
        focusRingType = .exterior
        controlSize = .small
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        onBeginEditing?()
    }

    func controlTextDidChange(_ notification: Notification) {
        onTextChange?(stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        onEndEditing?()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)), let onSubmit {
            onSubmit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

@MainActor
private final class FeedNativeBoxView: NSView {
    init(content: NSView, tint: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = tint.withAlphaComponent(0.055).cgColor
        layer?.borderColor = tint.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class FeedNativeBadgeView: NSView {
    init(text: String, foreground: NSColor, background: NSColor, monospacedDigits: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = background.cgColor
        let label = NSTextField(labelWithString: text)
        label.font = monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            : .systemFont(ofSize: 10, weight: .medium)
        label.textColor = foreground
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct FeedNativePermissionInputPreview {
    let sigil: String?
    let primary: String?
    let secondary: String?

    init(toolName: String, toolInputJSON: String) {
        let dictionary = (try? JSONSerialization.jsonObject(with: Data(toolInputJSON.utf8)))
            as? [String: Any] ?? [:]
        switch toolName.lowercased() {
        case "bash":
            sigil = "$"
            primary = (dictionary["command"] as? String) ?? toolInputJSON
            secondary = dictionary["description"] as? String
        case "write", "edit", "multiedit":
            sigil = nil
            primary = (dictionary["file_path"] as? String) ?? toolInputJSON
            if toolName.lowercased() == "write" {
                let content = (dictionary["content"] as? String) ?? ""
                let preview = content.split(separator: "\n").first.map(String.init) ?? ""
                secondary = preview.isEmpty ? nil : preview
            } else {
                secondary = nil
            }
        case "read":
            sigil = nil
            primary = (dictionary["file_path"] as? String) ?? toolInputJSON
            secondary = nil
        default:
            sigil = nil
            primary = toolInputJSON == "{}" ? nil : toolInputJSON
            secondary = nil
        }
    }
}

private extension FeedNativeItemSnapshot {
    var displayContext: WorkstreamContext? {
        let fallback = WorkstreamContext(lastUserMessage: userPromptEcho)
        let merged = context?.mergingMissing(from: fallback) ?? fallback
        return merged.isEmpty ? nil : merged
    }

    var promptEcho: String? {
        guard let value = userPromptEcho?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return String(localized: "feed.promptEcho", defaultValue: "You: \(value)")
    }

    var isResolvedOrExpired: Bool {
        switch status {
        case .resolved, .expired: return true
        case .pending, .telemetry: return false
        }
    }

    var headerTitle: String {
        let prompt = (displayContext?.lastUserMessage ?? userPromptEcho)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let questionHeader: String? = {
            guard case .question(_, let questions) = payload else { return nil }
            return questions.compactMap { $0.header?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }()
        let detail: String
        if !prompt.isEmpty {
            detail = [questionHeader, prompt].compactMap { $0 }.joined(separator: " · ")
        } else if let questionHeader {
            detail = questionHeader
        } else if let title, !title.isEmpty {
            detail = title
        } else {
            detail = kind.feedLabel.capitalized
        }
        guard let cwd, !cwd.isEmpty else { return detail }
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let basename = (trimmed as NSString).lastPathComponent
        return basename.isEmpty ? detail : "\(basename) · \(detail)"
    }

    var relativeTimeChip: String {
        let interval = Date().timeIntervalSince(createdAt)
        if interval < 60 { return "<1m" }
        if interval < 3_600 { return "\(Int(interval / 60))m" }
        if interval < 86_400 { return "\(Int(interval / 3_600))h" }
        return "\(Int(interval / 86_400))d"
    }

    var helpText: String {
        var lines = [headerTitle]
        if let cwd { lines.append(cwd) }
        lines.append(Self.absoluteFormatter.string(from: createdAt))
        return lines.joined(separator: "\n")
    }

    var resolvedBadgeLabel: String? {
        guard case .resolved(let decision, _) = status else { return nil }
        let submitted = String(localized: "feed.badge.submitted", defaultValue: "Submitted")
        switch decision {
        case .permission(let mode):
            return "\(submitted) · \(mode.feedDisplayLabel)"
        case .exitPlan(let mode, let feedback):
            if let feedback, !feedback.isEmpty {
                return "\(submitted) · " + String(localized: "feed.badge.refined", defaultValue: "refined")
            }
            return "\(submitted) · \(mode.feedDisplayLabel)"
        case .question:
            return submitted
        }
    }

    var telemetrySummary: String {
        switch payload {
        case .toolUse(let name, let json):
            return "\(name) \(json)"
        case .toolResult(let name, let json, let isError):
            let status = isError
                ? String(localized: "feed.telemetry.error", defaultValue: "error")
                : String(localized: "feed.telemetry.ok", defaultValue: "ok")
            return "\(name) \(status) \(json)"
        case .userPrompt(let text), .assistantMessage(let text):
            return text
        case .sessionStart:
            return String(localized: "feed.telemetry.sessionStart", defaultValue: "session start")
        case .sessionEnd:
            return String(localized: "feed.telemetry.sessionEnd", defaultValue: "session end")
        case .stop(let reason):
            let label = String(localized: "feed.telemetry.stop", defaultValue: "stop")
            guard let reason, !reason.isEmpty else { return label }
            return "\(label) \(reason)"
        default:
            return ""
        }
    }

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension WorkstreamKind {
    var feedSymbolName: String {
        switch self {
        case .permissionRequest: return "lock.shield"
        case .exitPlan: return "list.bullet.rectangle"
        case .question: return "questionmark.circle"
        case .toolUse, .toolResult: return "terminal"
        case .userPrompt: return "person"
        case .assistantMessage: return "sparkles"
        case .sessionStart, .sessionEnd: return "play.circle"
        case .stop: return "stop.circle"
        case .todos: return "checklist"
        }
    }

    var feedLabel: String {
        switch self {
        case .permissionRequest: return String(localized: "feed.kind.permission", defaultValue: "PERMISSION")
        case .exitPlan: return String(localized: "feed.kind.plan", defaultValue: "PLAN")
        case .question: return String(localized: "feed.kind.question.upper", defaultValue: "QUESTION")
        case .toolUse: return String(localized: "feed.kind.toolUse", defaultValue: "TOOL USE")
        case .toolResult: return String(localized: "feed.kind.toolResult", defaultValue: "TOOL RESULT")
        case .userPrompt: return String(localized: "feed.kind.prompt", defaultValue: "PROMPT")
        case .assistantMessage: return String(localized: "feed.kind.message", defaultValue: "MESSAGE")
        case .sessionStart: return String(localized: "feed.kind.sessionStart.upper", defaultValue: "SESSION START")
        case .sessionEnd: return String(localized: "feed.kind.sessionEnd.upper", defaultValue: "SESSION END")
        case .stop: return String(localized: "feed.kind.stop", defaultValue: "STOP")
        case .todos: return String(localized: "feed.kind.todos", defaultValue: "TODOS")
        }
    }

    func feedTint(status: WorkstreamStatus) -> NSColor {
        switch self {
        case .permissionRequest: return .systemOrange
        case .exitPlan: return .systemPurple
        case .question: return .systemBlue
        default: return status.isPending ? .systemOrange : .secondaryLabelColor
        }
    }
}

private extension WorkstreamSource {
    var feedForeground: NSColor {
        switch self {
        case .claude: return NSColor(red: 0.92, green: 0.54, blue: 0.29, alpha: 1)
        case .codex: return .systemGreen
        case .opencode: return .systemBlue
        case .hermesAgent: return .systemTeal
        case .cursor: return .systemPurple
        default: return .secondaryLabelColor
        }
    }
}

private extension WorkstreamPermissionMode {
    var feedDisplayLabel: String {
        switch self {
        case .once: return String(localized: "feed.permission.mode.once", defaultValue: "once")
        case .always: return String(localized: "feed.permission.mode.always", defaultValue: "always")
        case .all: return String(localized: "feed.permission.mode.all", defaultValue: "all tools")
        case .bypass: return String(localized: "feed.permission.mode.bypass", defaultValue: "bypass")
        case .deny: return String(localized: "feed.permission.mode.deny", defaultValue: "denied")
        }
    }
}

private extension WorkstreamExitPlanMode {
    var feedDisplayLabel: String {
        switch self {
        case .ultraplan: return String(localized: "feed.exitplan.mode.ultraplan", defaultValue: "ultraplan")
        case .bypassPermissions: return String(localized: "feed.exitplan.mode.bypass", defaultValue: "bypass")
        case .autoAccept: return String(localized: "feed.exitplan.mode.autoAccept", defaultValue: "auto")
        case .manual: return String(localized: "feed.exitplan.mode.manual", defaultValue: "manual")
        case .deny: return String(localized: "feed.exitplan.mode.deny", defaultValue: "denied")
        }
    }
}

private extension WorkstreamTaskTodo.State {
    var feedSymbolName: String {
        switch self {
        case .completed: return "checkmark.square.fill"
        case .inProgress: return "circle.fill"
        case .pending: return "square"
        }
    }
}
