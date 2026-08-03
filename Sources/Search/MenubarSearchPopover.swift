import AppKit
import CmuxFoundation

@MainActor
final class MenubarSearchPopover: NSObject, NSPopoverDelegate {
    private unowned let coordinator: GlobalSearchCoordinator
    private let popover = NSPopover()
    private let paletteController: GlobalSearchPaletteViewController
    private var dismissalHandler: (() -> Void)?

    var isShown: Bool { popover.isShown }

    init(coordinator: GlobalSearchCoordinator) {
        self.coordinator = coordinator
        paletteController = GlobalSearchPaletteViewController(coordinator: coordinator)
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 720, height: 460)
        popover.delegate = self
        popover.contentViewController = paletteController
    }

    func toggle(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        popover.isShown ? dismiss() : show(relativeTo: button, onDismiss: onDismiss)
    }

    func show(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        if popover.isShown { popover.performClose(nil) }
        dismissalHandler = onDismiss
        paletteController.prepareToShow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func dismiss() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        paletteController.didHide()
        let handler = dismissalHandler
        dismissalHandler = nil
        handler?()
    }
}

@MainActor
private final class GlobalSearchPaletteViewController: NSViewController,
    NSTextFieldDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    private static let debounceDuration = Duration.milliseconds(80)
    private static let browseResultLimit = 20
    private unowned let coordinator: GlobalSearchCoordinator
    private let queryField = NSTextField(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "")
    private var results: [GlobalSearchResultRow] = []
    private var selectedIndex = 0
    private var searchGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var keyMonitor: Any?

    init(coordinator: GlobalSearchCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 720, height: 460)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: preferredContentSize))
        backdrop.material = .popover
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        view = backdrop

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false

        queryField.placeholderString = String(
            localized: "globalSearch.palette.placeholder",
            defaultValue: "Search all windows, panels, browser tabs..."
        )
        queryField.font = GlobalFontMagnification.systemFont(ofSize: 18)
        queryField.isBordered = false
        queryField.isBezeled = false
        queryField.drawsBackground = false
        queryField.focusRingType = .none
        queryField.usesSingleLineMode = true
        queryField.delegate = self
        queryField.translatesAutoresizingMaskIntoConstraints = false
        queryField.setAccessibilityIdentifier("GlobalSearch.Query")

        let header = NSView(frame: .zero)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(icon)
        header.addSubview(queryField)

        let divider = NSBox(frame: .zero)
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("GlobalSearch.Result"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = .zero
        tableView.rowHeight = 76
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.setAccessibilityIdentifier("GlobalSearch.Results")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = GlobalFontMagnification.systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(divider)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 56),
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            queryField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            queryField.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
            queryField.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),
        ])
        updateResultsPresentation()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(queryField)
    }

    func prepareToShow() {
        loadViewIfNeeded()
        installKeyMonitorIfNeeded()
        resetResultsForPopoverOpen()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await coordinator.refreshLiveIndex()
            guard !Task.isCancelled else { return }
            scheduleSearch(queryField.stringValue)
        }
    }

    func didHide() {
        removeKeyMonitor()
        refreshTask?.cancel()
        refreshTask = nil
        cancelSearchWork()
    }

    deinit {
        searchTask?.cancel()
        refreshTask?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func controlTextDidChange(_ notification: Notification) {
        scheduleSearch(queryField.stringValue)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 76 }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("GlobalSearch.ResultRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? GlobalSearchResultRowView
            ?? GlobalSearchResultRowView(frame: .zero)
        view.identifier = identifier
        view.update(
            row: results[row],
            isSelected: row == selectedIndex,
            onActivate: { [weak self] in self?.openResult(at: row) },
            onHover: { [weak self] in self?.selectResult(at: row) }
        )
        return view
    }

    private func scheduleSearch(_ nextQuery: String) {
        cancelSearchWork()
        searchGeneration &+= 1
        let generation = searchGeneration
        let trimmed = nextQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reloadBrowseResults()
            return
        }
        searchTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.debounceDuration, clock: .continuous)
            } catch {
                return
            }
            guard let self, searchGeneration == generation, !Task.isCancelled else { return }
            let hits = await coordinator.search(query: trimmed)
            guard searchGeneration == generation, !Task.isCancelled else { return }
            results = hits.enumerated().map { offset, hit in
                GlobalSearchResultRow(hit: hit, query: trimmed, index: offset)
            }
            selectedIndex = min(selectedIndex, max(results.count - 1, 0))
            searchTask = nil
            updateResultsPresentation()
        }
    }

    private func cancelSearchWork() {
        searchTask?.cancel()
        searchTask = nil
    }

    private func resetResultsForPopoverOpen() {
        selectedIndex = 0
        let trimmed = queryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            reloadBrowseResults()
        } else {
            results = []
            updateResultsPresentation()
            scheduleSearch(trimmed)
        }
    }

    private func reloadBrowseResults() {
        let hits = coordinator.browseOpenPanels(limit: Self.browseResultLimit)
        results = hits.enumerated().map { offset, hit in
            GlobalSearchResultRow(hit: hit, query: "", index: offset)
        }
        selectedIndex = 0
        updateResultsPresentation()
    }

    private func updateResultsPresentation() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        emptyLabel.stringValue = queryField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
            ? String(localized: "globalSearch.empty.noOpenPanels", defaultValue: "No open panels")
            : String(localized: "globalSearch.empty.noResults", defaultValue: "No results")
        emptyLabel.isHidden = !results.isEmpty
        scrollView.isHidden = results.isEmpty
    }

    private func selectResult(at index: Int) {
        guard results.indices.contains(index), selectedIndex != index else { return }
        let previous = selectedIndex
        selectedIndex = index
        tableView.reloadData(forRowIndexes: IndexSet([previous, index]), columnIndexes: IndexSet(integer: 0))
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyEvent = GlobalSearchKeyEvent(event)
            let route = MainActor.assumeIsolated {
                AppDelegate.shared?.routeVisibleGlobalSearchShortcutFromLocalMonitor(event) ?? .notApplicable
            }
            switch route {
            case .handled:
                return nil
            case .queryOwnsEvent:
                return event
            case .notApplicable:
                let consumed = MainActor.assumeIsolated { self?.handleKeyEvent(keyEvent) ?? false }
                return consumed ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func handleKeyEvent(_ event: GlobalSearchKeyEvent) -> Bool {
        guard coordinator.isPaletteVisible() else { return false }
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
            coordinator.dismissPalette()
            return true
        case 126 where flags.isDisjoint(with: [.command, .shift, .option, .control]):
            selectResult(at: max(0, selectedIndex - 1))
            return true
        case 125 where flags.isDisjoint(with: [.command, .shift, .option, .control]):
            selectResult(at: min(max(results.count - 1, 0), selectedIndex + 1))
            return true
        case 36, 76:
            openResult(at: selectedIndex)
            return true
        default:
            if flags.contains(.command), !flags.contains(.option), !flags.contains(.control) {
                return !event.queryOwnsEditingShortcut && !isSystemCommand(event)
            }
            return false
        }
    }

    private func isSystemCommand(_ event: GlobalSearchKeyEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return ["h", "m", "q", "w", ","].contains(characters)
    }

    private func openResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        let row = results[index]
        coordinator.activate(row.hit, query: row.query)
    }
}

struct GlobalSearchKeyEvent: Sendable {
    let keyCode: UInt16
    let characters: String?
    let charactersIgnoringModifiers: String?
    private let modifierFlagsRawValue: UInt

    init(_ event: NSEvent) {
        keyCode = event.keyCode
        characters = event.characters
        charactersIgnoringModifiers = event.charactersIgnoringModifiers
        modifierFlagsRawValue = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }
}

private struct GlobalSearchResultRow: Equatable {
    let hit: SearchIndexHit
    let query: String
    let index: Int

    var title: String {
        let trimmed = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(localized: "globalSearch.untitled", defaultValue: "Untitled")
            : trimmed
    }

    var location: String { hit.location.trimmingCharacters(in: .whitespacesAndNewlines) }

    var snippet: String {
        let trimmed = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    var shortcutLabel: String? { index < 9 ? "⌘\(index + 1)" : nil }

    var systemImageName: String {
        switch hit.kind {
        case .browser: "globe"
        case .markdown: "doc.richtext"
        case .title: "rectangle.stack"
        }
    }
}

@MainActor
private final class GlobalSearchResultRowView: NSControl {
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(wrappingLabelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var trackingAreaReference: NSTrackingArea?
    private var onActivate: () -> Void = {}
    private var onHover: () -> Void = {}

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .semibold)
        kindLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        snippetLabel.font = GlobalFontMagnification.systemFont(ofSize: 12)
        locationLabel.font = GlobalFontMagnification.systemFont(ofSize: 11)
        shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        for label in [titleLabel, kindLabel, snippetLabel, locationLabel, shortcutLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        snippetLabel.maximumNumberOfLines = 2
        kindLabel.textColor = .secondaryLabelColor
        snippetLabel.textColor = .secondaryLabelColor
        locationLabel.textColor = .tertiaryLabelColor
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.alignment = .right

        let titleStack = NSStackView(views: [titleLabel, kindLabel])
        titleStack.orientation = .horizontal
        titleStack.alignment = .firstBaseline
        titleStack.spacing = 8
        let textStack = NSStackView(views: [titleStack, snippetLabel, locationLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        let rowStack = NSStackView(views: [iconView, textStack, shortcutLabel])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 12
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rowStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            shortcutLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        target = self
        action = #selector(activate)
        sendAction(on: .leftMouseUp)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        row: GlobalSearchResultRow,
        isSelected: Bool,
        onActivate: @escaping () -> Void,
        onHover: @escaping () -> Void
    ) {
        self.onActivate = onActivate
        self.onHover = onHover
        iconView.image = NSImage(systemSymbolName: row.systemImageName, accessibilityDescription: nil)
        iconView.contentTintColor = isSelected ? .labelColor : .secondaryLabelColor
        titleLabel.stringValue = row.title
        kindLabel.stringValue = row.hit.kind.localizedLabel
        snippetLabel.stringValue = row.snippet
        locationLabel.stringValue = row.location
        locationLabel.isHidden = row.location.isEmpty
        shortcutLabel.stringValue = row.shortcutLabel ?? ""
        shortcutLabel.isHidden = row.shortcutLabel == nil
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        setAccessibilityLabel("\(row.title), \(row.hit.kind.localizedLabel), \(row.snippet)")
        setAccessibilityIdentifier("GlobalSearch.Result.\(row.index)")
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHover() }

    @objc private func activate() { onActivate() }
}
