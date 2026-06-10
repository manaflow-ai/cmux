import AppKit
import Bonsplit
import Combine
import SwiftUI

#if DEBUG
func fileExplorerDebugResponder(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}
#endif

final class FileExplorerExternalOpenRequest: NSObject {
    let fileURL: URL
    let applicationURL: URL?

    init(fileURL: URL, applicationURL: URL?) {
        self.fileURL = fileURL
        self.applicationURL = applicationURL
    }
}

func addFileExplorerExternalOpenItems(
    to menu: NSMenu,
    fileURL: URL,
    target: AnyObject,
    action: Selector
) {
    let applications = FileExternalOpenApplicationResolver.live.applications(for: fileURL)
    let primaryApplication = applications.first { $0.isDefault } ?? applications.first
    let otherApplications = applications.filter { application in
        application.id != primaryApplication?.id
    }

    if let primaryApplication {
        let openItem = NSMenuItem(
            title: FileExternalOpenText.openInApplication(primaryApplication.displayName),
            action: action,
            keyEquivalent: ""
        )
        openItem.target = target
        openItem.representedObject = FileExplorerExternalOpenRequest(
            fileURL: fileURL,
            applicationURL: primaryApplication.url
        )
        menu.addItem(openItem)

        guard !otherApplications.isEmpty else { return }
        let openWithMenu = NSMenu(title: FileExternalOpenText.openWithMenu)
        for application in otherApplications {
            let appItem = NSMenuItem(
                title: application.displayName,
                action: action,
                keyEquivalent: ""
            )
            appItem.target = target
            appItem.representedObject = FileExplorerExternalOpenRequest(
                fileURL: fileURL,
                applicationURL: application.url
            )
            openWithMenu.addItem(appItem)
        }
        let openWithItem = NSMenuItem(title: FileExternalOpenText.openWithMenu, action: nil, keyEquivalent: "")
        openWithItem.submenu = openWithMenu
        menu.addItem(openWithItem)
    } else {
        let openItem = NSMenuItem(
            title: FileExternalOpenText.openExternally,
            action: action,
            keyEquivalent: ""
        )
        openItem.target = target
        openItem.representedObject = FileExplorerExternalOpenRequest(fileURL: fileURL, applicationURL: nil)
        menu.addItem(openItem)
    }
}

// MARK: - File Explorer Panel (single NSViewRepresentable)

enum FileExplorerPanelPresentation: Equatable {
    case files
    case find

    var rightSidebarMode: RightSidebarMode {
        switch self {
        case .files: return .files
        case .find: return .find
        }
    }
}

enum FileExplorerPanelPlacement: Equatable {
    case rightSidebar
    case pane
}

/// The entire file explorer panel as one AppKit view hierarchy.
/// Contains the header bar (path + controls) and NSOutlineView, with no SwiftUI intermediaries.
struct FileExplorerPanelView: NSViewRepresentable {
    @ObservedObject var store: FileExplorerStore
    @ObservedObject var state: FileExplorerState
    let onOpenFilePreview: (String) -> Void
    var presentation: FileExplorerPanelPresentation = .files
    var placement: FileExplorerPanelPlacement = .rightSidebar
    var onFocus: (() -> Void)?
    var onContainerChange: ((FileExplorerContainerView?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: onOpenFilePreview,
            placement: placement,
            onFocus: onFocus,
            onContainerChange: onContainerChange
        )
    }

    func makeNSView(context: Context) -> FileExplorerContainerView {
        let container = FileExplorerContainerView(coordinator: context.coordinator, presentation: presentation)
        context.coordinator.containerView = container
        context.coordinator.onContainerChange?(container)
        return container
    }

    func updateNSView(_ container: FileExplorerContainerView, context: Context) {
        context.coordinator.store = store
        context.coordinator.state = state
        context.coordinator.onOpenFilePreview = onOpenFilePreview
        context.coordinator.placement = placement
        context.coordinator.onFocus = onFocus
        context.coordinator.onContainerChange = onContainerChange
        context.coordinator.onContainerChange?(container)
        container.updateHeader(store: store)
        container.updatePresentation(presentation)
        context.coordinator.reloadIfNeeded()
        container.registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    static func dismantleNSView(_ nsView: FileExplorerContainerView, coordinator: Coordinator) {
        _ = nsView
        coordinator.onContainerChange?(nil)
    }

    // MARK: - Coordinator

}

// MARK: - Container View (all-AppKit)

/// Pure AppKit container holding the header bar and outline view.
@MainActor
final class FileExplorerContainerView: NSView {
    let headerView: FileExplorerHeaderView
    let searchBarView: NSView
    let searchField: FileExplorerSearchField
    let searchStatusLabel: NSTextField
    let scrollView: NSScrollView
    let outlineView: FileExplorerNSOutlineView
    let searchScrollView: NSScrollView
    let searchResultsView: FileExplorerSearchResultsTableView
    let emptyLabel: NSTextField
    let loadingIndicator: NSProgressIndicator
    let searchController: any FileSearchControlling
    var searchBarHeightConstraint: NSLayoutConstraint!
    var searchSnapshot = FileSearchSnapshot.empty
    var currentRootPath = ""
    var currentProviderIsLocal = false
    var currentContentRevision = 0
    let searchDebounceSubject = PassthroughSubject<Int, Never>()
    var searchDebounceCancellable: AnyCancellable?
    var searchDebounceGeneration = 0
    var pendingSearchRefreshAfterSettled = false
    var isSearchVisible = false {
        didSet {
            if !isSearchVisible {
                cancelPendingSearchRefresh()
                pendingSearchRefreshAfterSettled = false
            }
        }
    }
    var presentation: FileExplorerPanelPresentation
    let coordinator: FileExplorerPanelView.Coordinator
    let searchDebounceDelayMilliseconds = 200
    let searchBarVisibleHeight: CGFloat = 48

#if DEBUG
    var debugLastSearchTextChangeUptime: TimeInterval = 0
    var debugLastSearchLayoutFieldWidth: CGFloat = -1
    var debugLastSearchLayoutStatusWidth: CGFloat = -1
    var debugLastLoggedSearchResultCount = -1
    var debugLastLoggedSearchStatus = ""
#endif

    init(
        coordinator: FileExplorerPanelView.Coordinator,
        presentation: FileExplorerPanelPresentation,
        searchController: (any FileSearchControlling)? = nil
    ) {
        headerView = FileExplorerHeaderView()
        searchBarView = NSView()
        searchField = FileExplorerSearchField()
        searchStatusLabel = NSTextField(labelWithString: "")
        scrollView = NSScrollView()
        outlineView = FileExplorerNSOutlineView()
        searchScrollView = NSScrollView()
        searchResultsView = FileExplorerSearchResultsTableView()
        emptyLabel = NSTextField(labelWithString: String(localized: "fileExplorer.empty", defaultValue: "No folder open"))
        loadingIndicator = NSProgressIndicator()
        self.searchController = searchController ?? FileSearchController()
        self.presentation = presentation
        self.coordinator = coordinator

        super.init(frame: .zero)
        configureSearchDebounce()

        // Header
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        // Search bar
        searchBarView.translatesAutoresizingMaskIntoConstraints = false
        searchBarView.isHidden = true
        addSubview(searchBarView)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("FileExplorerSearchField")
        searchField.placeholderString = String(localized: "fileExplorer.search.placeholder", defaultValue: "Search files")
        searchField.font = .systemFont(ofSize: 12, weight: .regular)
        searchField.focusRingType = .none
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.cell?.lineBreakMode = .byClipping
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.delegate = self
        searchField.onCancel = { [weak self] in
            self?.closeSearchAndFocusOutline()
        }
        searchField.onMoveSelection = { [weak self] delta in
            self?.moveSearchSelection(by: delta, focusResults: true)
        }
        searchField.onCommit = { [weak self] in
            self?.openSelectedSearchResult()
        }
        searchField.onFocus = { [weak self] in
            guard let self else { return }
            self.isSearchVisible = true
            self.coordinator.noteKeyboardFocus(mode: self.representedRightSidebarMode(), in: self.window)
            self.updateSearchLayout()
        }
        searchBarView.addSubview(searchField)

        searchStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        searchStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        searchStatusLabel.textColor = .secondaryLabelColor
        searchStatusLabel.lineBreakMode = .byTruncatingTail
        searchStatusLabel.maximumNumberOfLines = 1
        searchStatusLabel.alignment = .left
        searchStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchBarView.addSubview(searchStatusLabel)

        // Empty state label
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        // Loading indicator
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        addSubview(loadingIndicator)

        // Outline view setup
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = FileExplorerStyle.current.indentation
        outlineView.allowsMultipleSelection = true
        outlineView.autoresizesOutlineColumn = true
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.onQuickSearchChanged = { [weak self] query in
            self?.headerView.updateQuickSearch(query: query)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.target = coordinator
        outlineView.doubleAction = #selector(FileExplorerPanelView.Coordinator.handleDoubleClick(_:))
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        coordinator.outlineView = outlineView

        // Context menu
        let menu = NSMenu()
        menu.delegate = coordinator
        outlineView.menu = menu

        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView
        addSubview(scrollView)

        // Streaming search results
        searchResultsView.headerView = nil
        searchResultsView.usesAlternatingRowBackgroundColors = false
        searchResultsView.style = .plain
        searchResultsView.selectionHighlightStyle = .regular
        searchResultsView.backgroundColor = .clear
        searchResultsView.rowHeight = 46
        searchResultsView.allowsMultipleSelection = true
        searchResultsView.intercellSpacing = NSSize(width: 0, height: 0)
        searchResultsView.onCancel = { [weak self] in
            self?.closeSearchAndFocusOutline()
        }
        searchResultsView.onMoveSelection = { [weak self] delta in
            self?.moveSearchSelection(by: delta, focusResults: false)
        }
        searchResultsView.onCommit = { [weak self] in
            self?.openSelectedSearchResult()
        }
        searchResultsView.onFocus = { [weak self] in
            guard let self else { return }
            self.coordinator.noteKeyboardFocus(mode: self.representedRightSidebarMode(), in: self.window)
        }
        searchResultsView.onModeShortcut = { [weak coordinator] mode, window in
            coordinator?.handleModeShortcut(mode, in: window) ?? false
        }
        let searchColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("searchResult"))
        searchColumn.isEditable = false
        searchColumn.resizingMask = .autoresizingMask
        searchResultsView.addTableColumn(searchColumn)
        searchResultsView.dataSource = self
        searchResultsView.delegate = self
        searchResultsView.target = self
        searchResultsView.doubleAction = #selector(openSelectedSearchResultFromTable(_:))
        searchResultsView.setDraggingSourceOperationMask(.move, forLocal: true)
        let searchMenu = NSMenu()
        searchMenu.delegate = self
        searchResultsView.menu = searchMenu

        searchScrollView.translatesAutoresizingMaskIntoConstraints = false
        searchScrollView.hasVerticalScroller = true
        searchScrollView.hasHorizontalScroller = false
        searchScrollView.horizontalScrollElasticity = .none
        searchScrollView.autohidesScrollers = true
        searchScrollView.borderType = .noBorder
        searchScrollView.drawsBackground = false
        searchScrollView.documentView = searchResultsView
        searchScrollView.isHidden = true
        addSubview(searchScrollView)

        self.searchController.onSnapshotChanged = { [weak self] snapshot in
            self?.applySearchSnapshot(snapshot)
        }

        searchBarHeightConstraint = searchBarView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),

            searchBarView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            searchBarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchBarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchBarHeightConstraint,

            searchField.leadingAnchor.constraint(equalTo: searchBarView.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchBarView.trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: searchBarView.topAnchor, constant: 4),
            searchField.heightAnchor.constraint(equalToConstant: 24),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            searchStatusLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: 4),
            searchStatusLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            searchStatusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 2),

            scrollView.topAnchor.constraint(equalTo: searchBarView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            searchScrollView.topAnchor.constraint(equalTo: searchBarView.bottomAnchor),
            searchScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelPendingSearchRefresh()
            searchController.cancel(clear: false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if coordinator.placement == .rightSidebar {
            AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFileExplorerHost(self)
        }
#if DEBUG
        dlog(
            "file.focus.host.attach win=\(window.windowNumber) canAccept=\(cmuxCanAcceptRightSidebarKeyboardFocus ? 1 : 0) " +
            "rows=\(outlineView.numberOfRows) hidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0) " +
            "fr=\(fileExplorerDebugResponder(window.firstResponder))"
        )
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard coordinator.placement == .rightSidebar else { return }
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFileExplorerHost(self)
    }

    override func layout() {
#if DEBUG
        let debugLayoutStart = ProcessInfo.processInfo.systemUptime
#endif
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
#if DEBUG
        logSearchLayoutIfNeeded(startedAt: debugLayoutStart, reason: "layout")
#endif
    }

}

