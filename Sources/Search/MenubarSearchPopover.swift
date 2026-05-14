import AppKit
import SwiftUI

@MainActor
final class MenubarSearchPopover: NSObject, NSPopoverDelegate {
    private unowned let coordinator: GlobalSearchCoordinator
    private let popover = NSPopover()

    var isShown: Bool {
        popover.isShown
    }

    init(coordinator: GlobalSearchCoordinator) {
        self.coordinator = coordinator
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 720, height: 460)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: GlobalSearchSurfaceView(coordinator: coordinator, placement: .popover)
        )
    }

    private var dismissalHandler: (() -> Void)?

    func toggle(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        if popover.isShown {
            dismiss()
        } else {
            show(relativeTo: button, onDismiss: onDismiss)
        }
    }

    func show(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        if popover.isShown {
            popover.performClose(nil)
        }
        dismissalHandler = onDismiss
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func dismiss() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        let handler = dismissalHandler
        dismissalHandler = nil
        handler?()
    }
}

enum GlobalSearchSurfacePlacement {
    case popover
    case rightSidebar
    case pane

    var fixedSize: CGSize? {
        switch self {
        case .popover:
            return CGSize(width: 720, height: 460)
        case .rightSidebar, .pane:
            return nil
        }
    }

    var headerHeight: CGFloat {
        switch self {
        case .popover:
            return 56
        case .rightSidebar, .pane:
            return 44
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .popover:
            return 18
        case .rightSidebar, .pane:
            return 12
        }
    }

    var searchFontSize: CGFloat {
        switch self {
        case .popover:
            return 18
        case .rightSidebar, .pane:
            return 14
        }
    }

    var rowHorizontalPadding: CGFloat {
        switch self {
        case .popover:
            return 14
        case .rightSidebar, .pane:
            return 10
        }
    }

    var rowVerticalPadding: CGFloat {
        switch self {
        case .popover:
            return 8
        case .rightSidebar, .pane:
            return 7
        }
    }

    var focusesSearchFieldOnAppear: Bool {
        switch self {
        case .popover, .pane:
            return true
        case .rightSidebar:
            return false
        }
    }
}

struct GlobalSearchSurfaceView: View {
    let coordinator: GlobalSearchCoordinator
    let placement: GlobalSearchSurfacePlacement
    var onFocusAnchorChange: (GlobalSearchKeyboardFocusView?) -> Void = { _ in }

    @State private var query = ""
    @State private var results: [GlobalSearchResultRow] = []
    @State private var selectedIndex = 0
    @State private var isSearching = false
    @State private var searchGeneration = 0
    @State private var searchDebounceTimer: DispatchSourceTimer?
    @State private var searchTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?
    @State private var keyMonitor: Any?
    @State private var focusAnchorBox = GlobalSearchFocusAnchorBox()
    @FocusState private var searchFieldFocused: Bool

    private let searchDebounceMilliseconds = 80
    private let browseResultLimit = 20

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    String(
                        localized: "globalSearch.palette.placeholder",
                        defaultValue: "Search all terminals, panels, browser tabs..."
                    ),
                    text: $query
                )
                .textFieldStyle(.plain)
                .font(.system(size: placement.searchFontSize, weight: .regular))
                .focused($searchFieldFocused)
                .accessibilityIdentifier("GlobalSearch.searchField")
            }
            .padding(.horizontal, placement.horizontalPadding)
            .frame(height: placement.headerHeight)

            Divider()

            if results.isEmpty {
                GlobalSearchEmptyStateView(
                    title: isSearching
                        ? String(localized: "globalSearch.empty.searching", defaultValue: "Searching...")
                        : query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? String(localized: "globalSearch.empty.noOpenPanels", defaultValue: "No open panels")
                        : String(localized: "globalSearch.empty.noResults", defaultValue: "No results")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { row in
                            GlobalSearchResultRowView(
                                row: row,
                                isSelected: selectedIndex == row.index,
                                placement: placement,
                                action: {
                                    selectedIndex = row.index
                                    openSelectedResult()
                                }
                            )
                            .onHover { hovering in
                                if hovering {
                                    selectedIndex = row.index
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .modifier(GlobalSearchSurfaceFrameModifier(placement: placement))
        .background(surfaceBackground)
        .background(
            GlobalSearchKeyboardFocusAnchor(
                placement: placement,
                onViewChange: attachFocusAnchor,
                onFocusSearchField: focusSearchFieldFromCoordinator
            )
            .frame(width: 0, height: 0)
        )
        .onAppear {
            if placement.focusesSearchFieldOnAppear {
                searchFieldFocused = true
            }
            installKeyMonitorIfNeeded()
            resetResultsForPopoverOpen()
            refreshTask?.cancel()
            refreshTask = Task { @MainActor in
                await coordinator.refreshLiveIndex()
                guard !Task.isCancelled else { return }
                scheduleSearch(query)
            }
        }
        .onDisappear {
            removeKeyMonitor()
            attachFocusAnchor(nil)
            refreshTask?.cancel()
            refreshTask = nil
            cancelSearchWork()
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue)
        }
    }

    @ViewBuilder
    private var surfaceBackground: some View {
        switch placement {
        case .popover:
            Rectangle()
                .fill(.regularMaterial)
        case .rightSidebar, .pane:
            Color(nsColor: .controlBackgroundColor)
        }
    }

    private func attachFocusAnchor(_ anchor: GlobalSearchKeyboardFocusView?) {
        focusAnchorBox.view = anchor
        onFocusAnchorChange(anchor)
    }

    private func focusSearchFieldFromCoordinator() -> Bool {
        searchFieldFocused = true
        return true
    }

    private func scheduleSearch(_ nextQuery: String) {
        cancelSearchWork()
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = nextQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSearching = false
            reloadBrowseResults()
            return
        }

        isSearching = true

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(searchDebounceMilliseconds), leeway: .milliseconds(15))
        timer.setEventHandler {
            Task { @MainActor in
                guard searchGeneration == generation else { return }
                searchDebounceTimer?.cancel()
                searchDebounceTimer = nil

                searchTask = Task { @MainActor in
                    defer {
                        if searchGeneration == generation {
                            searchTask = nil
                        }
                    }

                    guard searchGeneration == generation, !Task.isCancelled else { return }
                    let hits = await coordinator.search(query: trimmed)
                    guard searchGeneration == generation, !Task.isCancelled else { return }
                    results = hits.enumerated().map { offset, hit in
                        GlobalSearchResultRow(hit: hit, query: trimmed, index: offset)
                    }
                    selectedIndex = min(selectedIndex, max(results.count - 1, 0))
                    isSearching = false
                }
            }
        }
        searchDebounceTimer = timer
        timer.resume()
    }

    private func cancelSearchWork() {
        searchDebounceTimer?.cancel()
        searchDebounceTimer = nil
        searchTask?.cancel()
        searchTask = nil
    }

    private func resetResultsForPopoverOpen() {
        selectedIndex = 0
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            reloadBrowseResults()
            isSearching = false
        } else {
            results = []
            isSearching = true
        }
    }

    private func reloadBrowseResults() {
        let hits = coordinator.browseOpenPanels(limit: browseResultLimit)
        results = hits.enumerated().map { offset, hit in
            GlobalSearchResultRow(hit: hit, query: "", index: offset)
        }
        selectedIndex = 0
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyEvent = GlobalSearchKeyEvent(event)
            let consumed = MainActor.assumeIsolated {
                handleKeyEvent(keyEvent)
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: GlobalSearchKeyEvent) -> Bool {
        guard keyHandlingIsActive(for: event) else { return false }

        let flags = event.modifierFlags
        if flags.contains(.command),
           !flags.contains(.option),
           !flags.contains(.control),
           let rawDigit = event.charactersIgnoringModifiers,
           let digit = Int(rawDigit),
           (1...9).contains(digit) {
            openResult(at: digit - 1)
            return true
        }

        switch event.keyCode {
        case 53:
            guard placement == .popover else { return false }
            coordinator.dismissPalette()
            return true
        case 126:
            selectedIndex = max(0, selectedIndex - 1)
            return true
        case 125:
            selectedIndex = min(max(results.count - 1, 0), selectedIndex + 1)
            return true
        case 36, 76:
            openSelectedResult()
            return true
        default:
            if flags.contains(.command),
               !flags.contains(.option),
               !flags.contains(.control) {
                return !isTextEditingCommand(event) && !isSystemCommand(event)
            }
            return false
        }
    }

    private func keyHandlingIsActive(for event: GlobalSearchKeyEvent) -> Bool {
        switch placement {
        case .popover:
            return coordinator.isPaletteVisible()
        case .rightSidebar, .pane:
            guard let focusAnchorView = focusAnchorBox.view,
                  let window = focusAnchorView.window,
                  event.windowNumber == 0 || event.windowNumber == window.windowNumber,
                  let responder = window.firstResponder else {
                return false
            }
            return focusAnchorView.ownsKeyboardFocus(responder)
        }
    }

    private func isTextEditingCommand(_ event: GlobalSearchKeyEvent) -> Bool {
        if let characters = event.charactersIgnoringModifiers?.lowercased(),
           ["a", "c", "v", "x", "z"].contains(characters) {
            return true
        }

        switch event.keyCode {
        case 51, 117, 123, 124:
            return true
        default:
            return false
        }
    }

    private func isSystemCommand(_ event: GlobalSearchKeyEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return ["h", "m", "q", "w", ","].contains(characters)
    }

    private func openSelectedResult() {
        openResult(at: selectedIndex)
    }

    private func openResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        let row = results[index]
        coordinator.activate(row.hit, query: row.query)
    }
}

private final class GlobalSearchFocusAnchorBox {
    weak var view: GlobalSearchKeyboardFocusView?
}

private struct GlobalSearchSurfaceFrameModifier: ViewModifier {
    let placement: GlobalSearchSurfacePlacement

    func body(content: Content) -> some View {
        if let fixedSize = placement.fixedSize {
            content.frame(width: fixedSize.width, height: fixedSize.height)
        } else {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct GlobalSearchKeyEvent: Sendable {
    let keyCode: UInt16
    let charactersIgnoringModifiers: String?
    let windowNumber: Int
    private let modifierFlagsRawValue: UInt

    init(_ event: NSEvent) {
        keyCode = event.keyCode
        charactersIgnoringModifiers = event.charactersIgnoringModifiers
        windowNumber = event.windowNumber
        modifierFlagsRawValue = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }
}

private struct GlobalSearchKeyboardFocusAnchor: NSViewRepresentable {
    final class Coordinator {
        var placement: GlobalSearchSurfacePlacement
        var onViewChange: (GlobalSearchKeyboardFocusView?) -> Void
        var onFocusSearchField: () -> Bool
        weak var attachedView: GlobalSearchKeyboardFocusView?

        init(
            placement: GlobalSearchSurfacePlacement,
            onViewChange: @escaping (GlobalSearchKeyboardFocusView?) -> Void,
            onFocusSearchField: @escaping () -> Bool
        ) {
            self.placement = placement
            self.onViewChange = onViewChange
            self.onFocusSearchField = onFocusSearchField
        }

        func attach(_ view: GlobalSearchKeyboardFocusView) {
            view.placement = placement
            view.onFocusSearchField = onFocusSearchField
            guard attachedView !== view else { return }
            attachedView = view
            onViewChange(view)
        }

        func detach(_ view: GlobalSearchKeyboardFocusView) {
            guard attachedView === view else { return }
            attachedView = nil
            onViewChange(nil)
        }
    }

    let placement: GlobalSearchSurfacePlacement
    var onViewChange: (GlobalSearchKeyboardFocusView?) -> Void
    var onFocusSearchField: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            placement: placement,
            onViewChange: onViewChange,
            onFocusSearchField: onFocusSearchField
        )
    }

    func makeNSView(context: Context) -> GlobalSearchKeyboardFocusView {
        let view = GlobalSearchKeyboardFocusView()
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ nsView: GlobalSearchKeyboardFocusView, context: Context) {
        context.coordinator.placement = placement
        context.coordinator.onViewChange = onViewChange
        context.coordinator.onFocusSearchField = onFocusSearchField
        context.coordinator.attach(nsView)
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    static func dismantleNSView(_ nsView: GlobalSearchKeyboardFocusView, coordinator: Coordinator) {
        coordinator.detach(nsView)
    }
}

final class GlobalSearchKeyboardFocusView: NSView {
    var placement: GlobalSearchSurfacePlacement = .popover
    var onFocusSearchField: (() -> Bool)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard placement == .rightSidebar, let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerGlobalSearchHost(self)
    }

    func focusSearchFieldFromCoordinator() -> Bool {
        if onFocusSearchField?() == true {
            return true
        }
        guard let window else { return false }
        return window.makeFirstResponder(self)
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        guard let responderView = Self.view(for: responder) else { return false }
        guard let root = focusRootView else { return false }
        return responderView === root || responderView.isDescendant(of: root)
    }

    private static func view(for responder: NSResponder) -> NSView? {
        if let view = responder as? NSView {
            return view
        }
        if let textView = responder as? NSTextView,
           let delegateView = textView.delegate as? NSView {
            return delegateView
        }
        return nil
    }

    private var focusRootView: NSView? {
        guard let superview else { return nil }
        var current: NSView? = superview
        while let view = current {
            let typeName = String(describing: type(of: view))
            if typeName.contains("NSHosting") || typeName.contains("ViewHost") {
                return view
            }
            current = view.superview
        }
        return superview
    }
}

private struct GlobalSearchEmptyStateView: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

private struct GlobalSearchResultRow: Identifiable, Equatable {
    let hit: SearchIndexHit
    let query: String
    let index: Int

    var id: String { hit.id }

    var title: String {
        let trimmed = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(localized: "globalSearch.untitled", defaultValue: "Untitled")
            : trimmed
    }

    var location: String {
        hit.location.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var snippet: String {
        let trimmed = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    var shortcutLabel: String? {
        index < 9 ? "⌘\(index + 1)" : nil
    }

    var systemImageName: String {
        switch hit.kind {
        case .browser:
            return "globe"
        case .markdown:
            return "doc.richtext"
        case .terminal:
            return "terminal"
        case .title:
            return "rectangle.stack"
        }
    }
}

private struct GlobalSearchResultRowView: View {
    let row: GlobalSearchResultRow
    let isSelected: Bool
    let placement: GlobalSearchSurfacePlacement
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: row.systemImageName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(row.hit.kind.localizedLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(row.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !row.location.isEmpty {
                        Text(row.location)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let shortcutLabel = row.shortcutLabel {
                    Text(shortcutLabel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 30, alignment: .trailing)
                }
            }
            .padding(.horizontal, placement.rowHorizontalPadding)
            .padding(.vertical, placement.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("GlobalSearch.resultRow.\(row.index)")
    }
}
