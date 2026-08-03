import AppKit
import CmuxAppKitSupportUI

/// Owns the single Vault popover outside recycled native row graphs.
///
/// A row state change can arrive while AppKit is laying out its table. Keeping
/// the popover here lets the table finish its staged apply before hosted
/// popover content is replaced or measured, and keeps representable updates
/// out of that AppKit layout stack entirely.
@MainActor
final class SessionIndexTablePopoverPresenter: NSObject, NSPopoverDelegate {
    private let visibleUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()
    private let transcriptLayout: SessionTranscriptPopoverLayout
    private let transcriptSizeModel: SessionTranscriptPopoverSizeModel
    private var contentController: NSViewController?
    private var cancelContentWork: (() -> Void)?
    private var popover: NSPopover?
    private var currentPresentation: SessionIndexTablePopoverPresentation?
    private var pendingPresentation: (
        presentation: SessionIndexTablePopoverPresentation,
        anchorView: NSView,
        anchorRect: NSRect
    )?
    private weak var anchorView: NSView?
    private var isClosingProgrammatically = false

    var isPopoverShown: Bool { popover?.isShown == true }

    init(transcriptLayout: SessionTranscriptPopoverLayout = SessionTranscriptPopoverLayout()) {
        self.transcriptLayout = transcriptLayout
        transcriptSizeModel = SessionTranscriptPopoverSizeModel(size: transcriptLayout.defaultSize)
        super.init()
    }

    func reconcile(
        _ presentation: SessionIndexTablePopoverPresentation,
        relativeTo anchorRect: NSRect,
        of anchorView: NSView
    ) {
        guard anchorView.window != nil else { return }

        if isPopoverShown,
           currentPresentation?.identity == presentation.identity,
           self.anchorView === anchorView {
            let needsRefresh = currentPresentation?.hasEquivalentContent(to: presentation) != true
            currentPresentation = presentation
            if needsRefresh {
                scheduleVisibleRefresh()
            }
            return
        }

        pendingPresentation = (
            presentation: presentation,
            anchorView: anchorView,
            anchorRect: anchorRect
        )

        if isPopoverShown || isClosingProgrammatically {
            closeForReplacementIfNeeded()
        } else {
            presentPendingPresentation()
        }
    }

    func dismiss() {
        pendingPresentation = nil
        visibleUpdateScheduler.cancel()
        guard let popover, popover.isShown else {
            resetPresentedContent()
            return
        }
        isClosingProgrammatically = true
        popover.performClose(nil)
    }

    func dismissAndNotify() {
        let onDismiss = currentPresentation?.onDismiss
            ?? pendingPresentation?.presentation.onDismiss
        dismiss()
        onDismiss?()
    }

    func isAnchored(in view: NSView) -> Bool {
        guard let anchorView else { return false }
        return anchorView === view || anchorView.isDescendant(of: view)
    }

    private func closeForReplacementIfNeeded() {
        guard !isClosingProgrammatically else { return }
        guard let popover, popover.isShown else {
            resetPresentedContent()
            presentPendingPresentation()
            return
        }
        visibleUpdateScheduler.cancel()
        isClosingProgrammatically = true
        popover.performClose(nil)
    }

    private func presentPendingPresentation() {
        guard let pendingPresentation else { return }
        self.pendingPresentation = nil
        guard pendingPresentation.anchorView.window != nil else {
            pendingPresentation.presentation.onDismiss()
            return
        }

        currentPresentation = pendingPresentation.presentation
        anchorView = pendingPresentation.anchorView
        visibleUpdateScheduler.cancel()

        let popover = makePopover()
        refreshContent()
        popover.show(
            relativeTo: pendingPresentation.anchorRect,
            of: pendingPresentation.anchorView,
            preferredEdge: .maxX
        )
    }

    private func scheduleVisibleRefresh() {
        visibleUpdateScheduler.schedule { [weak self] in
            guard let self, self.isPopoverShown else { return }
            self.refreshContent()
        }
    }

    private func refreshContent() {
        guard let currentPresentation else { return }

        cancelContentWork?()

        switch currentPresentation.content {
        case let .section(section, search, loadSnapshot, onResume):
            let controller = SessionIndexSectionPopoverViewController(
                section: section,
                search: search,
                loadSnapshot: loadSnapshot,
                onResume: onResume,
                onDismiss: { [weak self] in self?.dismissAndNotify() }
            )
            installContentController(controller)
            cancelContentWork = { [weak controller] in controller?.cancelWork() }
        case .transcript(let entry):
            let controller = SessionTranscriptPreviewViewController(
                entry: entry,
                initialSize: transcriptSizeModel.size,
                onResize: { [weak self] proposedSize in self?.resizeTranscript(to: proposedSize) },
                onDismiss: { [weak self] in self?.dismissAndNotify() }
            )
            installContentController(controller)
            cancelContentWork = { [weak controller] in controller?.cancelWork() }
        }
        updateContentSize()
    }

    private func installContentController(_ controller: NSViewController) {
        controller.loadViewIfNeeded()
        contentController = controller
        popover?.contentViewController = controller
    }

    private func resizeTranscript(to proposedSize: CGSize) {
        transcriptSizeModel.size = transcriptLayout.clamped(proposedSize)
        updateContentSize()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        self.popover = popover
        return popover
    }

    private func updateContentSize() {
        guard let popover, let currentPresentation else { return }
        let size: NSSize
        switch currentPresentation.content {
        case .section:
            size = NSSize(width: 360, height: 480)
        case .transcript:
            size = NSSize(
                width: transcriptSizeModel.size.width,
                height: transcriptSizeModel.size.height
            )
        }
        CmuxPopoverMutation.setContentSize(size, on: popover)
    }

    private func resetPresentedContent() {
        visibleUpdateScheduler.cancel()
        cancelContentWork?()
        cancelContentWork = nil
        contentController = nil
        popover = nil
        currentPresentation = nil
        anchorView = nil
    }

    func popoverDidClose(_ notification: Notification) {
        let shouldNotify = !isClosingProgrammatically
        let onDismiss = currentPresentation?.onDismiss
        isClosingProgrammatically = false
        resetPresentedContent()

        if pendingPresentation != nil {
            presentPendingPresentation()
        } else if shouldNotify {
            onDismiss?()
        }
    }
}

@MainActor
private final class SessionIndexSectionPopoverViewController: NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate
{
    private static let pageSize = 100
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("SessionIndexPopover.entry")

    private let section: IndexSection
    private let search: SessionSearchFn
    private let loadSnapshot: DirectorySnapshotFn
    private let onResume: ((SessionEntry) -> Void)?
    private let onDismiss: () -> Void
    private let searchField = NSSearchField()
    private let tableView = SessionIndexPopoverTableView()
    private let scrollView = NSScrollView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private var queryTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var scrollObserver: NSObjectProtocol?
    private var loaded: [SessionEntry] = []
    private var fullSnapshot: [SessionEntry]?
    private var hasMore = true
    private var isLoading = false
    private var activeQuery = ""
    private var errorMessages: [String] = []

    init(
        section: IndexSection,
        search: @escaping SessionSearchFn,
        loadSnapshot: @escaping DirectorySnapshotFn,
        onResume: ((SessionEntry) -> Void)?,
        onDismiss: @escaping () -> Void
    ) {
        self.section = section
        self.search = search
        self.loadSnapshot = loadSnapshot
        self.onResume = onResume
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 360, height: 480)))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        let searchContainer = makeSearchContainer()
        let separator = NSBox()
        separator.boxType = .separator

        configureTable()
        configureStatusViews()

        for arrangedView in [header, searchContainer, separator, errorLabel, scrollView, footerLabel] {
            stack.addArrangedSubview(arrangedView)
        }
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            searchContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchContainer.heightAnchor.constraint(equalToConstant: 38),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerLabel.heightAnchor.constraint(equalToConstant: 24),
        ])
        view = root

        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.loadMoreIfNeeded() }
        }
        beginQueryLoad(debounce: false)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss()
    }

    func cancelWork() {
        queryTask?.cancel()
        queryTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
    }

    private func makeHeader() -> NSView {
        let header = NSView()
        let icon = NSImageView()
        icon.image = image(for: section.icon)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: section.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(icon)
        header.addSubview(title)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    private func makeSearchContainer() -> NSView {
        let container = NSView()
        searchField.placeholderString = String(
            localized: "sessionIndex.popover.searchPlaceholder",
            defaultValue: "Search Vault"
        )
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func configureTable() {
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 29
        tableView.intercellSpacing = .zero
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelectedRow)
        tableView.menuProvider = { [weak self] row in self?.contextMenu(for: row) }
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SessionIndexPopover.entryColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tableView.frame = scrollView.contentView.bounds
        tableView.autoresizingMask = [.width]
    }

    private func configureStatusViews() {
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemOrange
        errorLabel.backgroundColor = .systemOrange.withAlphaComponent(0.1)
        errorLabel.drawsBackground = true
        errorLabel.maximumNumberOfLines = 3
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -12),
        ])

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.alignment = .center
    }

    func controlTextDidChange(_ notification: Notification) {
        beginQueryLoad(debounce: true)
    }

    private func beginQueryLoad(debounce: Bool) {
        queryTask?.cancel()
        loadMoreTask?.cancel()
        loadMoreTask = nil
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        activeQuery = query
        errorMessages = []
        fullSnapshot = nil

        if query.isEmpty {
            loaded = section.entries
            hasMore = !section.entries.isEmpty
            isLoading = false
            render()
            guard case .directory(let path) = searchScope else { return }
            isLoading = true
            render()
            queryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let snapshot = await loadSnapshot(path)
                guard !Task.isCancelled else { return }
                fullSnapshot = snapshot.entries
                let count = min(Self.pageSize, snapshot.entries.count)
                loaded = Array(snapshot.entries.prefix(count))
                hasMore = count < snapshot.entries.count
                errorMessages = snapshot.errors
                isLoading = false
                render()
            }
            return
        }

        loaded = []
        hasMore = true
        isLoading = true
        render()
        queryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounce {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
            }
            let outcome = await search(query, searchScope, 0, Self.pageSize)
            guard !Task.isCancelled else { return }
            apply(outcome, append: false)
        }
    }

    private func loadMoreIfNeeded() {
        guard !isLoading, hasMore, !loaded.isEmpty else { return }
        let visibleMaxY = scrollView.contentView.bounds.maxY
        let contentMaxY = max(tableView.bounds.maxY, CGFloat(loaded.count) * tableView.rowHeight)
        guard contentMaxY <= visibleMaxY + 80 else { return }

        if let fullSnapshot {
            let count = min(loaded.count + Self.pageSize, fullSnapshot.count)
            loaded = Array(fullSnapshot.prefix(count))
            hasMore = count < fullSnapshot.count
            render()
            return
        }

        isLoading = true
        render()
        let query = activeQuery
        let scope = searchScope
        let offset = loaded.count
        loadMoreTask?.cancel()
        loadMoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await search(query, scope, offset, Self.pageSize)
            guard !Task.isCancelled else { return }
            apply(outcome, append: true)
        }
    }

    private func apply(_ outcome: SessionIndexStore.SearchOutcome, append: Bool) {
        if append {
            loaded.append(contentsOf: outcome.entries)
        } else {
            loaded = outcome.entries
        }
        hasMore = outcome.entries.count >= Self.pageSize
        errorMessages = outcome.errors
        isLoading = false
        render()
    }

    private func render() {
        tableView.reloadData()
        errorLabel.stringValue = errorMessages.joined(separator: "\n")
        errorLabel.isHidden = errorMessages.isEmpty
        if loaded.isEmpty {
            emptyLabel.stringValue = isLoading
                ? String(localized: "sessionIndex.popover.loading", defaultValue: "Loading…")
                : String(localized: "sessionIndex.popover.noMatches", defaultValue: "No matches")
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
        if isLoading {
            footerLabel.stringValue = String(localized: "sessionIndex.popover.loading", defaultValue: "Loading…")
        } else if !loaded.isEmpty, !hasMore {
            footerLabel.stringValue = String(
                localized: "sessionIndex.popover.endOfList",
                defaultValue: "You've reached the end"
            )
        } else {
            footerLabel.stringValue = ""
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.loadMoreIfNeeded()
        }
    }

    private var searchScope: SessionIndexStore.SearchScope {
        let raw = section.key.raw
        if raw.hasPrefix("agent:"),
           let agent = SessionAgent(rawValue: String(raw.dropFirst("agent:".count))) {
            return .agent(agent)
        }
        if raw.hasPrefix("dir:") {
            let path = String(raw.dropFirst("dir:".count))
            return .directory(path.isEmpty ? nil : path)
        }
        return .directory(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        loaded.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard loaded.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self)
            as? SessionIndexPopoverEntryCell) ?? SessionIndexPopoverEntryCell()
        cell.identifier = Self.cellIdentifier
        cell.configure(entry: loaded[row])
        return cell
    }

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard loaded.indices.contains(row) else { return nil }
        let entry = loaded[row]
        let dragID = SessionDragRegistry.shared.register(entry)
        guard let data = sessionTabTransferData(for: entry, dragId: dragID) else { return nil }
        let type = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        let dragPasteboard = NSPasteboard(name: .drag)
        dragPasteboard.addTypes([type], owner: nil)
        dragPasteboard.setData(data, forType: type)
        return item
    }

    @objc private func activateSelectedRow() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        activate(row: row)
    }

    private func activate(row: Int) {
        guard loaded.indices.contains(row) else { return }
        onResume?(loaded[row])
        onDismiss()
    }

    private func contextMenu(for row: Int) -> NSMenu? {
        guard loaded.indices.contains(row) else { return nil }
        let entry = loaded[row]
        let menu = NSMenu()
        if onResume != nil {
            menu.addItem(menuItem(
                String(localized: "sessionIndex.row.resume", defaultValue: "Resume in New Tab"),
                action: #selector(resumeEntry(_:)),
                entry: entry
            ))
            menu.addItem(.separator())
        }
        if entry.fileURL != nil {
            menu.addItem(menuItem(String(localized: "sessionIndex.row.open", defaultValue: "Open"), action: #selector(openEntry(_:)), entry: entry))
            menu.addItem(menuItem(String(localized: "sessionIndex.row.reveal", defaultValue: "Reveal in Finder"), action: #selector(revealEntry(_:)), entry: entry))
            menu.addItem(.separator())
            menu.addItem(menuItem(String(localized: "sessionIndex.row.copyPath", defaultValue: "Copy File Path"), action: #selector(copyEntryPath(_:)), entry: entry))
        }
        if entry.resumeCommand != nil {
            menu.addItem(menuItem(String(localized: "sessionIndex.row.copyResume", defaultValue: "Copy Resume Command"), action: #selector(copyResumeCommand(_:)), entry: entry))
        }
        if entry.cwd?.isEmpty == false {
            menu.addItem(menuItem(String(localized: "sessionIndex.row.openCwd", defaultValue: "Open Working Directory"), action: #selector(openWorkingDirectory(_:)), entry: entry))
        }
        if entry.pullRequest.flatMap({ URL(string: $0.url) }) != nil {
            menu.addItem(.separator())
            menu.addItem(menuItem(String(localized: "sessionIndex.row.openPR", defaultValue: "Open Pull Request"), action: #selector(openPullRequest(_:)), entry: entry))
        }
        return menu
    }

    private func menuItem(_ title: String, action: Selector, entry: SessionEntry) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = SessionIndexPopoverEntryBox(entry)
        return item
    }

    private func entry(from sender: Any?) -> SessionEntry? {
        ((sender as? NSMenuItem)?.representedObject as? SessionIndexPopoverEntryBox)?.entry
    }

    @objc private func resumeEntry(_ sender: Any?) {
        guard let entry = entry(from: sender) else { return }
        onResume?(entry)
        onDismiss()
    }

    @objc private func openEntry(_ sender: Any?) {
        guard let url = entry(from: sender)?.fileURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealEntry(_ sender: Any?) {
        guard let url = entry(from: sender)?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyEntryPath(_ sender: Any?) {
        copy(entry(from: sender)?.fileURL?.path)
    }

    @objc private func copyResumeCommand(_ sender: Any?) {
        copy(entry(from: sender)?.resumeCommand)
    }

    @objc private func openWorkingDirectory(_ sender: Any?) {
        guard let cwd = entry(from: sender)?.cwd, !cwd.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    @objc private func openPullRequest(_ sender: Any?) {
        guard let raw = entry(from: sender)?.pullRequest?.url,
              let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copy(_ value: String?) {
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func image(for icon: SectionIcon) -> NSImage? {
        switch icon {
        case .folder:
            return NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        case .agent(let agent):
            return sessionAgentImage(agent)
        }
    }
}

@MainActor
private final class SessionTranscriptPreviewViewController: NSViewController {
    private let entry: SessionEntry
    private let initialSize: NSSize
    private let onResize: (NSSize) -> Void
    private let onDismiss: () -> Void
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let statusStack = NSStackView()
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var loadTask: Task<Void, Never>?

    init(
        entry: SessionEntry,
        initialSize: NSSize,
        onResize: @escaping (NSSize) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.entry = entry
        self.initialSize = initialSize
        self.onResize = onResize
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: initialSize))
        let header = makeHeader()
        let separator = NSBox()
        separator.boxType = .separator
        header.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        configureTranscriptView()
        configureStatusView()

        let resizeHandle = SessionTranscriptResizeHandleView()
        resizeHandle.toolTip = String(
            localized: "sessionIndex.preview.resize",
            defaultValue: "Resize preview"
        )
        resizeHandle.onResize = onResize
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(separator)
        root.addSubview(scrollView)
        root.addSubview(statusStack)
        root.addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusStack.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 24),
            resizeHandle.heightAnchor.constraint(equalToConstant: 24),
        ])
        view = root
        showLoading()
        loadTranscript()
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss()
    }

    func cancelWork() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func makeHeader() -> NSView {
        let header = NSView()
        let icon = NSImageView()
        icon.image = sessionAgentImage(entry.agent)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: entry.displayTitle)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.addArrangedSubview(title)
        if let cwd = entry.cwdLabel {
            let cwdLabel = NSTextField(labelWithString: cwd)
            cwdLabel.font = .systemFont(ofSize: 11)
            cwdLabel.textColor = .secondaryLabelColor
            cwdLabel.lineBreakMode = .byTruncatingMiddle
            labels.addArrangedSubview(cwdLabel)
        }

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) ?? NSImage(),
            target: self,
            action: #selector(closePopover)
        )
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.toolTip = String(localized: "common.close", defaultValue: "Close")
        closeButton.setAccessibilityLabel(closeButton.toolTip)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(icon)
        header.addSubview(labels)
        header.addSubview(closeButton)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            labels.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        return header
    }

    private func configureTranscriptView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor.withAlphaComponent(0.35)
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureStatusView() {
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 8
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusStack.addArrangedSubview(spinner)
        statusStack.addArrangedSubview(statusIcon)
        statusStack.addArrangedSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusIcon.widthAnchor.constraint(equalToConstant: 14),
            statusIcon.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    private func loadTranscript() {
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let turns = try await SessionTranscriptLoader.load(entry: entry)
                guard !Task.isCancelled else { return }
                if turns.isEmpty {
                    showStatus(
                        systemImage: "text.bubble",
                        text: String(localized: "sessionIndex.preview.empty", defaultValue: "No previewable messages")
                    )
                } else {
                    show(turns: turns)
                }
            } catch SessionTranscriptLoadError.missingFile {
                guard !Task.isCancelled else { return }
                showStatus(
                    systemImage: "doc.badge.questionmark",
                    text: String(localized: "sessionIndex.preview.noFile", defaultValue: "No transcript file")
                )
            } catch {
                guard !Task.isCancelled else { return }
                showStatus(
                    systemImage: "exclamationmark.triangle.fill",
                    text: String(localized: "sessionIndex.preview.error", defaultValue: "Couldn't load transcript")
                )
            }
        }
    }

    private func showLoading() {
        scrollView.isHidden = true
        statusStack.isHidden = false
        statusIcon.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = String(localized: "sessionIndex.popover.loading", defaultValue: "Loading…")
    }

    private func showStatus(systemImage: String, text: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusIcon.isHidden = false
        statusIcon.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        statusLabel.stringValue = text
        statusStack.isHidden = false
        scrollView.isHidden = true
    }

    private func show(turns: [SessionTranscriptTurn]) {
        spinner.stopAnimation(nil)
        statusStack.isHidden = true
        scrollView.isHidden = false
        textView.textStorage?.setAttributedString(attributedTranscript(turns))
        textView.scrollToBeginningOfDocument(nil)
    }

    private func attributedTranscript(_ turns: [SessionTranscriptTurn]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, turn) in turns.enumerated() {
            let roleParagraph = NSMutableParagraphStyle()
            roleParagraph.paragraphSpacing = 2
            let bodyParagraph = NSMutableParagraphStyle()
            bodyParagraph.lineSpacing = 2
            bodyParagraph.paragraphSpacing = index == turns.count - 1 ? 0 : 10
            output.append(NSAttributedString(
                string: turn.role.label + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: turn.role.foregroundColor,
                    .paragraphStyle: roleParagraph,
                ]
            ))
            let font = turn.role.usesMonospacedBodyFont
                ? NSFont.monospacedSystemFont(ofSize: turn.role.bodyFontSize, weight: .regular)
                : NSFont.systemFont(ofSize: turn.role.bodyFontSize)
            output.append(NSAttributedString(
                string: turn.text + (index == turns.count - 1 ? "" : "\n\n"),
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor.withAlphaComponent(0.92),
                    .backgroundColor: turn.role.backgroundColor,
                    .paragraphStyle: bodyParagraph,
                ]
            ))
        }
        return output
    }

    @objc private func closePopover() {
        onDismiss()
    }
}

@MainActor
private final class SessionIndexPopoverTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menuProvider?(row)
    }
}

@MainActor
private final class SessionIndexPopoverEntryCell: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .right
        for child in [iconView, titleLabel, timeLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(entry: SessionEntry) {
        iconView.image = sessionAgentImage(entry.agent)
        titleLabel.stringValue = Self.flatten(entry.displayTitle)
        timeLabel.stringValue = Self.relativeFormatter.localizedString(for: entry.modified, relativeTo: .now)
        toolTip = entry.cwdLabel ?? entry.displayTitle
    }

    private static func flatten(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}

@MainActor
private final class SessionIndexPopoverEntryBox: NSObject {
    let entry: SessionEntry

    init(_ entry: SessionEntry) {
        self.entry = entry
    }
}

@MainActor
private final class SessionTranscriptResizeHandleView: NSView {
    var onResize: ((NSSize) -> Void)?
    private var startSize: NSSize?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let gesture = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(gesture)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setStroke()
        for offset in stride(from: CGFloat(5), through: 15, by: 5) {
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: bounds.maxX - offset, y: bounds.minY + 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + offset))
            path.stroke()
        }
    }

    @objc private func handlePan(_ sender: NSPanGestureRecognizer) {
        switch sender.state {
        case .began:
            startSize = window?.contentView?.bounds.size ?? superview?.bounds.size
        case .changed:
            guard let startSize else { return }
            let translation = sender.translation(in: self)
            onResize?(NSSize(
                width: startSize.width + translation.x,
                height: startSize.height - translation.y
            ))
        case .ended, .cancelled, .failed:
            startSize = nil
        default:
            break
        }
    }
}

@MainActor
private func sessionAgentImage(_ agent: SessionAgent) -> NSImage? {
    let image = agent.assetName.flatMap { NSImage(named: NSImage.Name($0)) }
        ?? NSImage(
            systemSymbolName: agent.systemImageName ?? "person.crop.circle",
            accessibilityDescription: nil
        )
    image?.size = NSSize(width: 14, height: 14)
    return image
}

extension SessionIndexTableRow {
    var popoverPresentation: SessionIndexTablePopoverPresentation? {
        guard case let .section(
            section,
            _,
            _,
            popoverIdentity,
            _,
            actions,
            _,
            setPopoverOpen
        ) = self,
        let popoverIdentity,
        popoverIdentity.sectionKey == section.key else {
            return nil
        }

        switch popoverIdentity {
        case .transcript(_, let entryID):
            guard let entryID = Self.containedPreviewEntryID(entryID, in: section),
                  let entry = section.entries.first(where: { $0.id == entryID }) else {
                return nil
            }
            return SessionIndexTablePopoverPresentation(
                identity: .transcript(section: section.key, entry: entry.id),
                content: .transcript(entry),
                onDismiss: { actions.onDismissPreview(entry.id) }
            )
        case .section:
            return SessionIndexTablePopoverPresentation(
                identity: .section(section.key),
                content: .section(
                    section: section,
                    search: actions.search,
                    loadSnapshot: actions.loadSnapshot,
                    onResume: actions.onResume
                ),
                onDismiss: { setPopoverOpen(false) }
            )
        }
    }
}
