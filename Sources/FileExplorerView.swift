import AppKit
import CmuxFileTree
import Bonsplit
import Combine
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxWorkspaces
import CmuxSettings
import SwiftUI

#if DEBUG
private func fileExplorerDebugResponder(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}
#endif

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
    @Environment(\.colorScheme) private var colorScheme

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
        container.appearance = WindowAppearanceSnapshot.appKitAppearance(for: colorScheme)
        context.coordinator.containerView = container
        context.coordinator.onContainerChange?(container)
        return container
    }

    func updateNSView(_ container: FileExplorerContainerView, context: Context) {
        container.appearance = WindowAppearanceSnapshot.appKitAppearance(for: colorScheme)
        context.coordinator.store = store
        context.coordinator.state = state
        context.coordinator.onOpenFilePreview = onOpenFilePreview
        context.coordinator.placement = placement
        context.coordinator.onFocus = onFocus
        context.coordinator.onContainerChange = onContainerChange
        context.coordinator.onContainerChange?(container)
        if store.showHiddenFiles != state.showHiddenFiles { store.showHiddenFiles = state.showHiddenFiles }
        if store.sortOrder != state.sortOrder { store.sortOrder = state.sortOrder }
        container.updateShortcutPlacement(placement)
        container.updateHeader(store: store)
        container.updatePresentation(presentation)
        context.coordinator.reloadIfNeeded()
        container.registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    static func dismantleNSView(_ nsView: FileExplorerContainerView, coordinator: Coordinator) {
        // A native source is still allowed to own the container through its
        // matching `endedAt` callback. When no session was promoted, however,
        // clear any stale delegate marker so a dismantled search table does not
        // retain an obsolete native-session identity.
        nsView.clearNativeDragMarkersIfIdle()
        coordinator.onContainerChange?(nil)
    }
}

// MARK: - Container View (all-AppKit)

/// Pure AppKit container holding the header bar and either the Files outline
/// or the Find panel.
@MainActor
final class FileExplorerContainerView: NSView {
    private let headerView: FileExplorerHeaderView
    private let scrollView: NSScrollView
    private let outlineView: FileExplorerNSOutlineView
    /// The Find mode's query bar and results. Hidden in the Files presentation.
    let findPanel: FileSearchPanelView
    private let emptyLabel: NSTextField
    private let loadingIndicator: NSProgressIndicator
    private var currentRootPath = ""
    var currentResourceContextID: UUID?
    private var currentWorkspaceRootIdentity: UUID?
    private var hasContent = false
    private var isLoading = false
    private var presentation: FileExplorerPanelPresentation
    let coordinator: FileExplorerPanelView.Coordinator
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?

    /// The Find results outline.
    var searchResultsView: FileExplorerSearchResultsTableView { findPanel.resultsView }

    private var isFindPresented: Bool { presentation == .find }

    /// - Parameter makeSearchSession: Builds per-workspace Find sessions.
    ///   Tests inject sessions with a manual clock.
    init(
        coordinator: FileExplorerPanelView.Coordinator,
        presentation: FileExplorerPanelPresentation,
        makeSearchSession: (@MainActor () -> FileSearchSession)? = nil
    ) {
        headerView = FileExplorerHeaderView()
        scrollView = NSScrollView()
        outlineView = FileExplorerNSOutlineView()
        findPanel = FileSearchPanelView(coordinator: coordinator, makeSession: makeSearchSession ?? { FileSearchSession() })
        emptyLabel = NSTextField(wrappingLabelWithString: String(localized: "fileExplorer.empty", defaultValue: "No folder open"))
        loadingIndicator = NSProgressIndicator()
        self.presentation = presentation
        self.coordinator = coordinator

        super.init(frame: .zero)
        // Direct test/fixture construction bypasses NSViewRepresentable's
        // makeNSView hook; keep the coordinator's current-container identity
        // correct for native drag ownership in both paths.
        coordinator.containerView = self
        updateShortcutPlacement(coordinator.placement)

        // Header
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        // Find
        findPanel.translatesAutoresizingMaskIntoConstraints = false
        findPanel.isHidden = true
        findPanel.onDismiss = { [weak self] in self?.dismissFind() }
        findPanel.onFocus = { [weak self, weak coordinator] in
            guard let self else { return }
            coordinator?.noteKeyboardFocus(mode: .find, in: self.window)
        }
        addSubview(findPanel)

        // Empty state label
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        // Loading indicator
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        addSubview(loadingIndicator)
        applyChromeFonts()
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.applyChromeFonts()
            self?.coordinator.rebuildOutline()
            self?.findPanel.applyFontScale()
        }

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
        outlineView.rowHeight = FileExplorerStyle.current.rowHeight
        outlineView.usesAutomaticRowHeights = false
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
        outlineView.onNativeDragPointerBoundary = { [weak coordinator, weak outlineView] in
            guard let outlineView else { return }
            coordinator?.prepareForNativeDragBoundary(on: outlineView)
        }
        outlineView.doubleAction = #selector(FileExplorerPanelView.Coordinator.handleDoubleClick(_:))
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        // Finder, terminals and other apps accept dragged file URLs as copies or links.
        outlineView.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.draggingDestinationFeedbackStyle = .regular
        headerView.viewOptionsMenuProvider = { [weak coordinator] in
            let menu = NSMenu()
            coordinator?.addViewOptionItems(to: menu)
            return menu
        }
        outlineView.onContextMenuDidClose = { [weak coordinator] in
            coordinator?.contextMenuDidClose()
        }

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
        coordinator.outlineView = outlineView

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            findPanel.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            findPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            findPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            findPanel.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateContentLayout()
        findPanel.setActive(isFindPresented)
    }

    private func applyChromeFonts() {
        emptyLabel.font = GlobalFontMagnification.systemFont(ofSize: 13)
        headerView.applyFonts()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            findPanel.setActive(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        refreshRemoteTreeIfNeeded()
        if coordinator.placement == .rightSidebar {
            AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFileExplorerHost(self)
        }
        findPanel.setActive(isFindPresented)
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
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func updateHeader(store: FileExplorerStore) {
        currentRootPath = store.rootPath
        currentResourceContextID = store.resourceContextID
        currentWorkspaceRootIdentity = store.workspaceRootIdentity
        headerView.update(displayPath: store.displayRootPath,
            retry: store.provider is CloudVMFileExplorerProvider ? { [weak store] in store?.retryRemoteRoot() } : nil)
        findPanel.update(store: store)
    }

    func representedRightSidebarMode() -> RightSidebarMode {
        presentation.rightSidebarMode
    }

    func updateShortcutPlacement(_ placement: FileExplorerPanelPlacement) {
        findPanel.queryBar.queryField.fileExplorerPanelPlacement = placement
        outlineView.fileExplorerPanelPlacement = placement
        searchResultsView.fileExplorerPanelPlacement = placement
    }

    func updatePresentation(_ nextPresentation: FileExplorerPanelPresentation) {
        guard presentation != nextPresentation else { return }
        presentation = nextPresentation
        updateContentLayout()
        findPanel.setActive(isFindPresented)
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func updateVisibility(
        hasContent: Bool,
        isLoading: Bool,
        statusMessage: String?,
        showsRemoteTarget: Bool = false
    ) {
        let normalizedStatus = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStatus = normalizedStatus?.isEmpty == false
        let canShowTree = hasContent && !hasStatus
        self.hasContent = canShowTree
        self.isLoading = isLoading
        applyHidden(headerView, !hasContent && !hasStatus && !showsRemoteTarget)
        updateContentLayout()
        let findCanShow = isFindPresented && canShowTree && !isLoading
        let nextEmptyText = hasStatus
            ? normalizedStatus!
            : String(localized: "fileExplorer.empty", defaultValue: "No folder open")
        if emptyLabel.stringValue != nextEmptyText {
            emptyLabel.stringValue = nextEmptyText
        }
        applyHidden(emptyLabel, canShowTree || findCanShow || isLoading)
        // Toggle the spinner only when the loading state actually changes.
        if applyHidden(loadingIndicator, !isLoading) {
            if isLoading {
                loadingIndicator.startAnimation(nil)
            } else {
                loadingIndicator.stopAnimation(nil)
            }
        }
    }

    /// Shows either the Files outline or the Find panel.
    private func updateContentLayout() {
        // Assigning isHidden unconditionally fires KVO even when unchanged,
        // which re-enters updateNSView and spins the main thread on macOS 26 (#4931).
        // Loading hides Find's results, not its query bar: hiding the field
        // that is being edited would end editing and drop shortcut focus.
        var changed = false
        if applyHidden(findPanel, !isFindPresented) { changed = true }
        if findPanel.setResultsHidden(!hasContent || isLoading) { changed = true }
        if applyHidden(scrollView, isFindPresented || !hasContent || isLoading) { changed = true }
        if changed {
            needsLayout = true
        }
    }

    /// Sets `isHidden` only when it changes (a redundant write still fires KVO), returning whether it changed.
    @discardableResult
    private func applyHidden(_ view: NSView, _ hidden: Bool) -> Bool {
        guard view.isHidden != hidden else { return false }
        view.isHidden = hidden
        return true
    }

    /// Focuses Find's query field. A `seed` (the selection Find was invoked
    /// with) replaces the query and searches immediately.
    @discardableResult
    func focusSearchField(seed: String? = nil) -> Bool {
        guard window != nil, cmuxCanAcceptRightSidebarKeyboardFocus else {
#if DEBUG
            dlog(
                "file.focus.search.end result=0 reason=unavailable " +
                "win=\(window?.windowNumber ?? -1) hidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0)"
            )
#endif
            return false
        }
        let result = findPanel.focusQueryField(seed: seed)
#if DEBUG
        dlog(
            "file.focus.search.end result=\(result ? 1 : 0) win=\(window?.windowNumber ?? -1) " +
            "seedLen=\(seed?.count ?? 0) fr=\(fileExplorerDebugResponder(window?.firstResponder))"
        )
#endif
        return result
    }

    @discardableResult
    func focusOutline() -> Bool {
#if DEBUG
        dlog(
            "file.focus.outline.begin win=\(window?.windowNumber ?? -1) " +
            "canAccept=\(cmuxCanAcceptRightSidebarKeyboardFocus ? 1 : 0) " +
            "hostHidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0) scrollHidden=\(scrollView.isHidden ? 1 : 0) " +
            "outlineHidden=\(outlineView.isHiddenOrHasHiddenAncestor ? 1 : 0) " +
            "rows=\(outlineView.numberOfRows) selected=\(outlineView.selectedRow) " +
            "fr=\(fileExplorerDebugResponder(window?.firstResponder))"
        )
#endif
        guard let window, cmuxCanAcceptRightSidebarKeyboardFocus else {
#if DEBUG
            dlog(
                "file.focus.outline.end result=0 reason=unavailable " +
                "win=\(window?.windowNumber ?? -1) hidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0)"
            )
#endif
            return false
        }
        (outlineView.dataSource as? FileExplorerPanelView.Coordinator)?
            .ensureSelection(in: outlineView, fallbackToFirstVisible: true, scroll: true)
        refreshRemoteTreeIfNeeded()
        let result = window.makeFirstResponder(outlineView)
#if DEBUG
        dlog(
            "file.focus.outline.end result=\(result ? 1 : 0) win=\(window.windowNumber) " +
            "rows=\(outlineView.numberOfRows) selected=\(outlineView.selectedRow) " +
            "fr=\(fileExplorerDebugResponder(window.firstResponder))"
        )
#endif
        return result
    }

    /// SSH and Cloud trees have no change stream; re-list what is visible
    /// when the panel is shown or focused.
    private func refreshRemoteTreeIfNeeded() {
        guard coordinator.store.provider is any RemoteFileExplorerProvider else { return }
        coordinator.store.refreshVisibleDirectories()
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === outlineView { return true }
        return findPanel.ownsResponder(responder)
    }

    /// Escape in Find with nothing to clear hands focus back to the terminal.
    private func dismissFind() {
        if AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() == true {
            return
        }
        window?.makeFirstResponder(nil)
    }

    /// Reclaims a Find drag whose terminal callback was lost.
    func prepareForNativeDragBoundary() {
        findPanel.prepareForNativeDragBoundary()
    }

    func clearNativeDragMarkersIfIdle() {
        findPanel.clearNativeDragMarkersIfIdle()
        guard outlineView.activeNativeDragSession == nil else { return }
        for ownership in outlineView.activeNativeDragOwnerships {
            ownership.revokeRouting()
        }
        outlineView.activeNativeDragDelegateMarker = nil
        outlineView.activeNativeDragWriter?.releaseSourceGraph()
        outlineView.activeNativeDragWriter = nil
        outlineView.activeNativeDragOwnerships = []
        outlineView.activeNativeDragOwnership = nil
    }
}
