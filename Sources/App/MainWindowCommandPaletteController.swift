import AppKit
import CmuxCommandPalette
import CmuxFoundation
import CmuxSettings
import CmuxUpdater

let commandPaletteOverlayContainerIdentifier = NSUserInterfaceItemIdentifier(
    "cmux.commandPalette.overlay.container"
)

@MainActor
private final class MainWindowCommandPaletteOverlayView: NSView {
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }
}

@MainActor
private final class MainWindowCommandPaletteSearchField: NSTextField {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onDeleteBackwardFromEmptyInput: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        font = .systemFont(ofSize: 13)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func keyDown(with event: NSEvent) {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 36, 76:
            onSubmit?()
        case 53:
            onEscape?()
        case 125:
            onMoveSelection?(1)
        case 126:
            onMoveSelection?(-1)
        case 51 where stringValue.isEmpty:
            onDeleteBackwardFromEmptyInput?()
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class MainWindowCommandPaletteDescriptionTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 36, 76:
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            if flags.contains(.shift) {
                insertNewline(nil)
            } else {
                onSubmit?()
            }
        case 53:
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }
}

/// Window-scoped AppKit owner for command-palette presentation and interaction.
///
/// The controller keeps palette state out of the window composition root and
/// mounts only AppKit views. Commands are materialized from the live AppKit menu
/// action graph, while switcher rows target the window's `TabManager` directly.
@MainActor
final class MainWindowCommandPaletteController: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    private enum Presentation {
        case list
        case rename(CommandPaletteRenameTarget)
        case workspaceDescription(CommandPaletteWorkspaceDescriptionTarget)
    }

    private let windowId: UUID
    private let tabManager: TabManager
    private weak var hostView: NSView?
    private let windowProvider: () -> NSWindow?
    private let supplementalCatalog: MainWindowCommandPaletteSupplementalCatalog

    private let overlayView = MainWindowCommandPaletteOverlayView(frame: .zero)
    private let panelView = NSVisualEffectView(frame: .zero)
    private let panelHitRegion = CommandPalettePanelHitRegionView(frame: .zero)
    private let contentHostView = NSView(frame: .zero)
    private let renderModel = CommandPaletteOverlayRenderModel()
    private let interactionMonitor = CommandPaletteInteractionMonitor()
    private let focusScheduler = MainActorDeferredActionScheduler()

    private var panelHeightConstraint: NSLayoutConstraint!
    private var searchField: MainWindowCommandPaletteSearchField?
    private var renameField: MainWindowCommandPaletteSearchField?
    private var descriptionTextView: MainWindowCommandPaletteDescriptionTextView?
    private var commandListView: CommandPaletteCommandListNativeView?
    private var presentation: Presentation = .list
    private var query = ""
    private var selectedIndex = 0
    private var resultsVersion: UInt64 = 0
    private var visibleResults: [CommandPaletteSearchResult] = []
    private var commandsByID: [String: CommandPaletteCommand] = [:]
    private var previousFirstResponder: NSResponder?
    private var renameDraft = ""
    private var descriptionDraft = ""
    private var isVisible = false

    init(
        windowId: UUID,
        tabManager: TabManager,
        updateViewModel: UpdateStateModel,
        notificationStore: TerminalNotificationStore,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState,
        fileExplorerState: FileExplorerState,
        cmuxConfigStore: CmuxConfigStore,
        hostView: NSView,
        windowProvider: @escaping () -> NSWindow?,
        openRightSidebarToolPane: @escaping (RightSidebarMode) -> Void
    ) {
        self.windowId = windowId
        self.tabManager = tabManager
        self.hostView = hostView
        self.windowProvider = windowProvider
        self.supplementalCatalog = MainWindowCommandPaletteSupplementalCatalog(
            windowId: windowId,
            tabManager: tabManager,
            updateViewModel: updateViewModel,
            notificationStore: notificationStore,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState,
            cmuxConfigStore: cmuxConfigStore,
            windowProvider: windowProvider,
            openRightSidebarToolPane: openRightSidebarToolPane
        )
        super.init()
        configureOverlay(in: hostView)
    }

    isolated deinit {
        interactionMonitor.deactivate()
        focusScheduler.cancel()
    }

    func teardown() {
        dismiss(restoreFocus: false)
        interactionMonitor.deactivate()
        focusScheduler.cancel()
        overlayView.removeFromSuperview()
    }

    func handles(_ notification: Notification) -> Bool {
        guard let window = windowProvider() else { return false }
        if let requestedWindow = notification.object as? NSWindow {
            return requestedWindow === window
        }
        return window.isKeyWindow || window.isMainWindow
    }

    func toggleCommands() {
        if isVisible {
            dismiss()
        } else {
            openCommands()
        }
    }

    func openCommands() {
        showList(query: ">")
    }

    func openSwitcher() {
        showList(query: "")
    }

    func openRenameWorkspace() {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        let target = CommandPaletteRenameTarget(
            kind: .workspace(workspaceId: workspace.id),
            currentName: workspaceDisplayName(workspace)
        )
        showRename(target)
    }

    func openRenameTab() {
        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            NSSound.beep()
            return
        }
        let target = CommandPaletteRenameTarget(
            kind: .tab(workspaceId: workspace.id, panelId: panelId),
            currentName: panelDisplayName(
                workspace: workspace,
                panelId: panelId,
                fallback: panel.displayTitle
            )
        )
        showRename(target)
    }

    func openWorkspaceDescription() {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        showWorkspaceDescription(
            CommandPaletteWorkspaceDescriptionTarget(
                workspaceId: workspace.id,
                currentDescription: workspace.customDescription ?? ""
            )
        )
    }

    func moveSelection(by delta: Int) {
        guard isVisible, case .list = presentation, !visibleResults.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), visibleResults.count - 1)
        publishRows()
    }

    func submit() {
        guard isVisible else { return }
        switch presentation {
        case .list:
            runSelectedResult()
        case .rename(let target):
            applyRename(target: target)
        case .workspaceDescription(let target):
            applyWorkspaceDescription(target: target)
        }
    }

    func handleRenameInputInteraction() {
        guard isVisible, case .rename = presentation else { return }
        focus(renameField, selection: renameSelectionRange)
    }

    func handleRenameDeleteBackwardFromEmptyInput() {
        guard isVisible, case .rename = presentation else { return }
        guard renameDraft.isEmpty else {
            (windowProvider()?.firstResponder as? NSTextView)?.deleteBackward(nil)
            return
        }
        showList(query: ">")
    }

    func dismiss(restoreFocus: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        focusScheduler.cancel()
        interactionMonitor.deactivate()
        overlayView.isHidden = true
        searchField = nil
        renameField = nil
        descriptionTextView = nil
        commandListView = nil
        contentHostView.subviews.forEach { $0.removeFromSuperview() }

        if let window = windowProvider() {
            AppDelegate.shared?.setCommandPaletteVisible(false, for: window)
            AppDelegate.shared?.setCommandPaletteSelectionIndex(0, for: window)
            AppDelegate.shared?.setCommandPaletteSnapshot(.empty, for: window)
            if restoreFocus {
                restorePreviousFocus(in: window)
            }
        }
        previousFirstResponder = nil
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === searchField {
            query = field.stringValue
            selectedIndex = 0
            refreshResults()
        } else if field === renameField {
            renameDraft = field.stringValue
            publishDebugSnapshot()
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              textView === descriptionTextView else { return }
        descriptionDraft = textView.string
        publishDebugSnapshot()
    }

    private var isCommandList: Bool {
        query.hasPrefix(">")
    }

    private var matchingQuery: String {
        let text = isCommandList ? String(query.dropFirst()) : query
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var renameSelectionRange: NSRange {
        let length = (renameDraft as NSString).length
        if CommandPaletteSettingsStore(defaults: .standard).renameSelectsAllOnFocus {
            return NSRange(location: 0, length: length)
        }
        return NSRange(location: length, length: 0)
    }

    private func configureOverlay(in hostView: NSView) {
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.identifier = commandPaletteOverlayContainerIdentifier
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = NSColor.clear.cgColor
        overlayView.isHidden = true

        panelView.translatesAutoresizingMaskIntoConstraints = false
        panelView.material = .menu
        panelView.blendingMode = .withinWindow
        panelView.state = .active
        panelView.wantsLayer = true
        panelView.layer?.cornerRadius = 8
        panelView.layer?.masksToBounds = false
        panelView.layer?.borderWidth = 1
        panelView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        panelView.shadow = NSShadow()
        panelView.layer?.shadowColor = NSColor.black.cgColor
        panelView.layer?.shadowOpacity = 0.24
        panelView.layer?.shadowRadius = 10
        panelView.layer?.shadowOffset = CGSize(width: 0, height: -5)
        panelView.setAccessibilityIdentifier("CommandPalettePanel")

        panelHitRegion.translatesAutoresizingMaskIntoConstraints = false
        contentHostView.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(panelHitRegion)
        panelView.addSubview(contentHostView)
        overlayView.addSubview(panelView)
        hostView.addSubview(overlayView, positioned: .above, relativeTo: nil)

        let targetWidth = panelView.widthAnchor.constraint(equalToConstant: 560)
        targetWidth.priority = .defaultHigh
        panelHeightConstraint = panelView.heightAnchor.constraint(equalToConstant: 360)
        NSLayoutConstraint.activate([
            overlayView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: hostView.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
            panelView.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            panelView.topAnchor.constraint(equalTo: overlayView.topAnchor, constant: 40),
            targetWidth,
            panelView.widthAnchor.constraint(lessThanOrEqualTo: overlayView.widthAnchor, constant: -32),
            panelView.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            panelHeightConstraint,
            panelHitRegion.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            panelHitRegion.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            panelHitRegion.topAnchor.constraint(equalTo: panelView.topAnchor),
            panelHitRegion.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),
            contentHostView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            contentHostView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            contentHostView.topAnchor.constraint(equalTo: panelView.topAnchor),
            contentHostView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),
        ])
    }

    private func showList(query: String) {
        beginPresentationIfNeeded()
        presentation = .list
        self.query = query
        selectedIndex = 0
        rebuildListContent()
        refreshResults()
        focus(searchField, selection: NSRange(location: (query as NSString).length, length: 0))
    }

    private func showRename(_ target: CommandPaletteRenameTarget) {
        beginPresentationIfNeeded()
        presentation = .rename(target)
        renameDraft = target.currentName
        rebuildRenameContent(target: target)
        publishDebugSnapshot()
        focus(renameField, selection: renameSelectionRange)
    }

    private func showWorkspaceDescription(_ target: CommandPaletteWorkspaceDescriptionTarget) {
        beginPresentationIfNeeded()
        presentation = .workspaceDescription(target)
        descriptionDraft = target.currentDescription
        rebuildWorkspaceDescriptionContent(target: target)
        publishDebugSnapshot()
        focus(descriptionTextView, selection: NSRange(location: (descriptionDraft as NSString).length, length: 0))
    }

    private func beginPresentationIfNeeded() {
        guard let window = windowProvider(), let hostView else { return }
        if !isVisible {
            previousFirstResponder = window.firstResponder
            isVisible = true
            overlayView.isHidden = false
            AppDelegate.shared?.setCommandPaletteVisible(true, for: window)
        }
        hostView.addSubview(overlayView, positioned: .above, relativeTo: nil)
        interactionMonitor.activate(
            for: window,
            shouldDismiss: { [weak self, weak window] event in
                guard let self, window != nil else { return false }
                return event.shouldDismissPalette(
                    panelContainsPoint: self.overlayView.commandPalettePanelContains(
                        windowPoint: event.locationInWindow
                    )
                )
            },
            onWindowStateChange: { [weak self] in
                self?.restorePaletteFocusIfNeeded()
            },
            onDismiss: { [weak self] dismissal in
                self?.dismiss(restoreFocus: dismissal != .windowResignedKey)
            }
        )
    }

    private func rebuildListContent() {
        resetContentHost()
        panelHeightConstraint.constant = 360

        let field = MainWindowCommandPaletteSearchField(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.stringValue = query
        field.placeholderString = isCommandList
            ? String(localized: "commandPalette.search.commandsPlaceholder", defaultValue: "Type a command")
            : String(localized: "commandPalette.search.switcherPlaceholder", defaultValue: "Search workspaces")
        field.setAccessibilityIdentifier("CommandPaletteSearchField")
        field.onSubmit = { [weak self] in self?.runSelectedResult() }
        field.onEscape = { [weak self] in self?.dismiss() }
        field.onMoveSelection = { [weak self] in self?.moveSelection(by: $0) }
        searchField = field

        let fieldContainer = NSView(frame: .zero)
        fieldContainer.translatesAutoresizingMaskIntoConstraints = false
        fieldContainer.addSubview(field)

        let separator = makeSeparator()
        let list = CommandPaletteCommandListNativeView(
            renderModel: renderModel,
            onRunResult: { [weak self] id in self?.runResult(id: id) }
        )
        list.translatesAutoresizingMaskIntoConstraints = false
        list.setAccessibilityIdentifier("CommandPaletteResultList")
        commandListView = list

        contentHostView.addSubview(fieldContainer)
        contentHostView.addSubview(separator)
        contentHostView.addSubview(list)
        NSLayoutConstraint.activate([
            fieldContainer.leadingAnchor.constraint(equalTo: contentHostView.leadingAnchor),
            fieldContainer.trailingAnchor.constraint(equalTo: contentHostView.trailingAnchor),
            fieldContainer.topAnchor.constraint(equalTo: contentHostView.topAnchor),
            fieldContainer.heightAnchor.constraint(equalToConstant: 37),
            field.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor, constant: 9),
            field.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor, constant: -9),
            field.centerYAnchor.constraint(equalTo: fieldContainer.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: contentHostView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentHostView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: fieldContainer.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            list.leadingAnchor.constraint(equalTo: contentHostView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: contentHostView.trailingAnchor),
            list.topAnchor.constraint(equalTo: separator.bottomAnchor),
            list.bottomAnchor.constraint(equalTo: contentHostView.bottomAnchor),
        ])
    }

    private func rebuildRenameContent(target: CommandPaletteRenameTarget) {
        resetContentHost()
        panelHeightConstraint.constant = 72

        let field = MainWindowCommandPaletteSearchField(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.stringValue = renameDraft
        field.placeholderString = target.placeholder
        field.setAccessibilityIdentifier("CommandPaletteRenameField")
        field.onSubmit = { [weak self] in self?.applyRename(target: target) }
        field.onEscape = { [weak self] in self?.dismiss() }
        field.onDeleteBackwardFromEmptyInput = { [weak self] in self?.showList(query: ">") }
        renameField = field

        let separator = makeSeparator()
        let hint = makeHintLabel(renameInputHint(target: target))
        contentHostView.addSubview(field)
        contentHostView.addSubview(separator)
        contentHostView.addSubview(hint)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: contentHostView.leadingAnchor, constant: 9),
            field.trailingAnchor.constraint(equalTo: contentHostView.trailingAnchor, constant: -9),
            field.topAnchor.constraint(equalTo: contentHostView.topAnchor, constant: 7),
            field.heightAnchor.constraint(equalToConstant: 22),
            separator.leadingAnchor.constraint(equalTo: contentHostView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentHostView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 7),
            separator.heightAnchor.constraint(equalToConstant: 1),
            hint.leadingAnchor.constraint(equalTo: contentHostView.leadingAnchor, constant: 9),
            hint.trailingAnchor.constraint(equalTo: contentHostView.trailingAnchor, constant: -9),
            hint.topAnchor.constraint(equalTo: separator.bottomAnchor),
            hint.bottomAnchor.constraint(equalTo: contentHostView.bottomAnchor),
        ])
    }

    private func rebuildWorkspaceDescriptionContent(target: CommandPaletteWorkspaceDescriptionTarget) {
        resetContentHost()
        panelHeightConstraint.constant = 228

        let textView = MainWindowCommandPaletteDescriptionTextView(frame: .zero)
        textView.delegate = self
        textView.string = descriptionDraft
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.setAccessibilityIdentifier("CommandPaletteWorkspaceDescriptionEditor")
        textView.setAccessibilityLabel(String(
            localized: "command.editWorkspaceDescription.title",
            defaultValue: "Edit Workspace Description…"
        ))
        textView.onSubmit = { [weak self] in self?.applyWorkspaceDescription(target: target) }
        textView.onEscape = { [weak self] in self?.dismiss() }
        descriptionTextView = textView

        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        let separator = makeSeparator()
        let hint = makeHintLabel(target.inputHint)
        contentHostView.addSubview(scrollView)
        contentHostView.addSubview(separator)
        contentHostView.addSubview(hint)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentHostView.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: contentHostView.trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: contentHostView.topAnchor, constant: 4),
            scrollView.heightAnchor.constraint(equalToConstant: 184),
            separator.leadingAnchor.constraint(equalTo: contentHostView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentHostView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            separator.heightAnchor.constraint(equalToConstant: 1),
            hint.leadingAnchor.constraint(equalTo: contentHostView.leadingAnchor, constant: 9),
            hint.trailingAnchor.constraint(equalTo: contentHostView.trailingAnchor, constant: -9),
            hint.topAnchor.constraint(equalTo: separator.bottomAnchor),
            hint.bottomAnchor.constraint(equalTo: contentHostView.bottomAnchor),
        ])
    }

    private func resetContentHost() {
        focusScheduler.cancel()
        searchField = nil
        renameField = nil
        descriptionTextView = nil
        commandListView = nil
        contentHostView.subviews.forEach { $0.removeFromSuperview() }
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox(frame: .zero)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.boxType = .separator
        return box
    }

    private func makeHintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    private func refreshResults() {
        guard isVisible, case .list = presentation else { return }
        let commands = isCommandList ? menuCommands() : switcherCommands()
        commandsByID = Dictionary(commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let corpus = commands.map { command in
            CommandPaletteSearchCorpusEntry(
                payload: command.id,
                rank: command.rank,
                title: command.title,
                searchableTexts: command.searchableTexts
            )
        }
        let matches = CommandPaletteSearchEngine(entries: corpus).search(
            query: matchingQuery,
            resultLimit: 200,
            historyBoost: { _, _ in 0 }
        )
        visibleResults = matches.compactMap { match in
            guard let command = commandsByID[match.payload] else { return nil }
            return CommandPaletteSearchResult(
                command: command,
                score: match.score,
                titleMatchIndices: match.titleMatchIndices
            )
        }
        selectedIndex = visibleResults.isEmpty ? 0 : min(selectedIndex, visibleResults.count - 1)
        searchField?.placeholderString = isCommandList
            ? String(localized: "commandPalette.search.commandsPlaceholder", defaultValue: "Type a command")
            : String(localized: "commandPalette.search.switcherPlaceholder", defaultValue: "Search workspaces")
        publishRows()
    }

    private func publishRows() {
        resultsVersion &+= 1
        let rows = visibleResults.map { result in
            let trailing: CommandPaletteRenderTrailingLabel?
            if let shortcutHint = result.command.shortcutHint, !shortcutHint.isEmpty {
                trailing = CommandPaletteRenderTrailingLabel(text: shortcutHint, style: .shortcut)
            } else if let kindLabel = result.command.kindLabel, !kindLabel.isEmpty {
                trailing = CommandPaletteRenderTrailingLabel(text: kindLabel, style: .kind)
            } else {
                trailing = nil
            }
            return CommandPaletteRenderResultRow(
                id: result.id,
                title: result.command.title,
                matchedIndices: result.titleMatchIndices,
                trailingLabel: trailing
            )
        }
        let selectedID = rows.indices.contains(selectedIndex) ? rows[selectedIndex].id : nil
        renderModel.scheduleCommandListUpdate(
            CommandPaletteCommandListRenderState(
                resultsVersion: resultsVersion,
                emptyStateText: isCommandList
                    ? String(localized: "commandPalette.search.commandsEmpty", defaultValue: "No commands match your search.")
                    : String(localized: "commandPalette.search.switcherEmpty", defaultValue: "No workspaces match your search."),
                listIdentity: isCommandList ? "commands" : "switcher",
                rows: rows,
                selectedIndex: selectedIndex,
                shouldShowEmptyState: rows.isEmpty,
                scrollTargetID: selectedID,
                scrollTargetAnchor: nil
            )
        )
        if let window = windowProvider() {
            AppDelegate.shared?.setCommandPaletteSelectionIndex(selectedIndex, for: window)
        }
        publishDebugSnapshot()
    }

    private func publishDebugSnapshot() {
        guard let window = windowProvider() else { return }
        let mode: String
        let debugResults: [CommandPaletteDebugResultRow]
        switch presentation {
        case .list:
            mode = "commands"
            debugResults = visibleResults.map { result in
                CommandPaletteDebugResultRow(
                    commandId: result.id,
                    title: result.command.title,
                    shortcutHint: result.command.shortcutHint,
                    trailingLabel: result.command.kindLabel,
                    score: result.score
                )
            }
        case .rename:
            mode = "rename_input"
            debugResults = []
        case .workspaceDescription:
            mode = "workspace_description_input"
            debugResults = []
        }
        AppDelegate.shared?.setCommandPaletteSnapshot(
            CommandPaletteDebugSnapshot(query: query, mode: mode, results: debugResults),
            for: window
        )
    }

    private func runSelectedResult() {
        guard visibleResults.indices.contains(selectedIndex) else {
            NSSound.beep()
            return
        }
        runResult(id: visibleResults[selectedIndex].id)
    }

    private func runResult(id: String) {
        guard let command = commandsByID[id] else { return }
        if command.dismissOnRun {
            dismiss()
        }
        command.action()
        if !command.dismissOnRun {
            refreshResults()
        }
    }

    private func switcherCommands() -> [CommandPaletteCommand] {
        var commands: [CommandPaletteCommand] = []
        commands.reserveCapacity(tabManager.tabs.count * 2)
        var rank = 0
        let includeSurfaces = !matchingQuery.isEmpty
        for workspace in tabManager.tabs {
            let workspaceName = workspaceDisplayName(workspace)
            let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            commands.append(
                CommandPaletteCommand(
                    id: "switcher.workspace.\(workspace.id.uuidString)",
                    rank: rank,
                    title: workspaceName,
                    subtitle: String(localized: "commandPalette.subtitle.workspaceFallback", defaultValue: "Workspace"),
                    shortcutHint: nil,
                    kindLabel: String(localized: "commandPalette.subtitle.workspaceFallback", defaultValue: "Workspace"),
                    keywords: directory.isEmpty ? ["workspace"] : ["workspace", directory],
                    dismissOnRun: true,
                    action: { [weak tabManager] in
                        tabManager?.focusTab(workspace.id, suppressFlash: true)
                    }
                )
            )
            rank += 1

            guard includeSurfaces else { continue }
            for panel in workspace.panels.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let panelTitle = panelDisplayName(
                    workspace: workspace,
                    panelId: panel.id,
                    fallback: panel.displayTitle
                )
                let kind = panel.panelType.rawValue
                commands.append(
                    CommandPaletteCommand(
                        id: "switcher.surface.\(workspace.id.uuidString).\(panel.id.uuidString)",
                        rank: rank,
                        title: panelTitle,
                        subtitle: workspaceName,
                        shortcutHint: nil,
                        kindLabel: kind.capitalized,
                        keywords: [workspaceName, kind, "surface", "tab"],
                        dismissOnRun: true,
                        action: { [weak tabManager] in
                            tabManager?.focusTab(
                                workspace.id,
                                surfaceId: panel.id,
                                suppressFlash: true
                            )
                        }
                    )
                )
                rank += 1
            }
        }
        return commands
    }

    private func menuCommands() -> [CommandPaletteCommand] {
        guard let menu = NSApp.mainMenu else { return [] }
        var commands: [CommandPaletteCommand] = []
        var rank = 0
        appendMenuCommands(
            from: menu,
            path: [],
            indexPath: [],
            commands: &commands,
            rank: &rank
        )
        for descriptor in CommandPaletteSettingsToggleCommands.descriptors
            where descriptor.isAvailable(.standard) {
            commands.append(
                CommandPaletteCommand(
                    id: descriptor.commandId,
                    rank: rank,
                    title: descriptor.commandTitle(),
                    subtitle: descriptor.commandSubtitle(),
                    shortcutHint: nil,
                    kindLabel: String(localized: "commandPalette.kind.settings", defaultValue: "Settings"),
                    keywords: descriptor.keywords + ["settings", "toggle", descriptor.settingsKey],
                    dismissOnRun: false,
                    action: { descriptor.toggle() }
                )
            )
            rank += 1
        }
        commands.append(contentsOf: supplementalCatalog.commands(startingAt: &rank))
        if tabManager.selectedWorkspace?.focusedPanelId != nil {
            commands.append(CommandPaletteCommand(
                id: "palette.renameTab",
                rank: rank,
                title: String(localized: "command.renameTab.title", defaultValue: "Rename Tab…"),
                subtitle: String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab"),
                shortcutHint: KeyboardShortcutSettings.shortcutIfBound(for: .renameTab)?.displayString,
                kindLabel: nil,
                keywords: ["rename", "tab", "title"],
                dismissOnRun: false,
                action: { [weak self] in self?.openRenameTab() }
            ))
            rank += 1
        }
        return commands
    }

    private func appendMenuCommands(
        from menu: NSMenu,
        path: [String],
        indexPath: [Int],
        commands: inout [CommandPaletteCommand],
        rank: inout Int
    ) {
        menu.update()
        for (index, item) in menu.items.enumerated() {
            guard !item.isSeparatorItem, !item.isHidden else { continue }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let nextPath = path + [title]
            let nextIndexPath = indexPath + [index]
            if let submenu = item.submenu {
                appendMenuCommands(
                    from: submenu,
                    path: nextPath,
                    indexPath: nextIndexPath,
                    commands: &commands,
                    rank: &rank
                )
                continue
            }
            guard item.action != nil, item.isEnabled else { continue }
            guard !isPaletteOpeningMenuItem(item) else { continue }
            // Generated menu graphs can reuse identifiers across unrelated
            // items. The position is unique within this live graph and keeps
            // command lookup from collapsing them onto the first item.
            let identifier = nextIndexPath.map(String.init).joined(separator: ".")
            let subtitle = path.dropFirst().joined(separator: " › ")
            commands.append(
                CommandPaletteCommand(
                    id: "menu.\(identifier)",
                    rank: rank,
                    title: title,
                    subtitle: subtitle,
                    shortcutHint: menuShortcutHint(for: item),
                    kindLabel: nil,
                    keywords: nextPath + ["menu"],
                    dismissOnRun: true,
                    action: { [weak item] in
                        guard let item, let action = item.action else { return }
                        _ = NSApp.sendAction(action, to: item.target, from: item)
                    }
                )
            )
            rank += 1
        }
    }

    private func isPaletteOpeningMenuItem(_ item: NSMenuItem) -> Bool {
        let titles = [
            KeyboardShortcutSettings.Action.commandPalette.label,
            KeyboardShortcutSettings.Action.goToWorkspace.label,
        ]
        return titles.contains(item.title)
    }

    private func menuShortcutHint(for item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let flags = item.keyEquivalentModifierMask
        var value = ""
        if flags.contains(.control) { value += "⌃" }
        if flags.contains(.option) { value += "⌥" }
        if flags.contains(.shift) { value += "⇧" }
        if flags.contains(.command) { value += "⌘" }
        value += item.keyEquivalent.uppercased()
        return value
    }

    private func applyRename(target: CommandPaletteRenameTarget) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String? = trimmed.isEmpty ? nil : trimmed
        switch target.kind {
        case .workspace(let workspaceId):
            tabManager.setCustomTitle(tabId: workspaceId, title: normalized)
        case .tab(let workspaceId, let panelId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                NSSound.beep()
                return
            }
            workspace.setPanelCustomTitle(panelId: panelId, title: normalized)
        }
        dismiss()
    }

    private func applyWorkspaceDescription(target: CommandPaletteWorkspaceDescriptionTarget) {
        guard tabManager.tabs.contains(where: { $0.id == target.workspaceId }) else {
            NSSound.beep()
            return
        }
        tabManager.setCustomDescription(tabId: target.workspaceId, description: descriptionDraft)
        dismiss()
    }

    private func focus(_ responder: NSResponder?, selection: NSRange) {
        guard let responder else { return }
        focusScheduler.schedule(zeroDelayPolicy: .yieldOnce) { [weak self, weak responder] in
            guard let self, let responder, self.isVisible,
                  let window = self.windowProvider() else { return }
            _ = window.makeFirstResponder(responder)
            if let editor = window.firstResponder as? NSTextView {
                let length = (editor.string as NSString).length
                let location = min(selection.location, length)
                let selectedLength = min(selection.length, length - location)
                editor.setSelectedRange(NSRange(location: location, length: selectedLength))
            }
        }
    }

    private func restorePaletteFocusIfNeeded() {
        guard isVisible, windowProvider()?.isKeyWindow == true else { return }
        switch presentation {
        case .list:
            focus(searchField, selection: NSRange(location: (query as NSString).length, length: 0))
        case .rename:
            focus(renameField, selection: renameSelectionRange)
        case .workspaceDescription:
            focus(
                descriptionTextView,
                selection: NSRange(location: (descriptionDraft as NSString).length, length: 0)
            )
        }
    }

    private func restorePreviousFocus(in window: NSWindow) {
        guard let previousFirstResponder else {
            _ = window.makeFirstResponder(nil)
            return
        }
        if let view = previousFirstResponder as? NSView {
            guard view.window === window,
                  !view.isHiddenOrHasHiddenAncestor,
                  view === window.contentView || view.superview != nil else { return }
        }
        _ = window.makeFirstResponder(previousFirstResponder)
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        let custom = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty
            ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
            : title
    }

    private func panelDisplayName(workspace: Workspace, panelId: UUID, fallback: String) -> String {
        let title = workspace.panelTitle(panelId: panelId)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        let fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty
            ? String(localized: "panel.displayName.fallback", defaultValue: "Tab")
            : fallback
    }

    private func renameInputHint(target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return String(
                localized: "commandPalette.rename.workspaceInputHint",
                defaultValue: "Enter a workspace name. Press Enter to rename, Escape to cancel."
            )
        case .tab:
            return String(
                localized: "commandPalette.rename.tabInputHint",
                defaultValue: "Enter a tab name. Press Enter to rename, Escape to cancel."
            )
        }
    }
}
