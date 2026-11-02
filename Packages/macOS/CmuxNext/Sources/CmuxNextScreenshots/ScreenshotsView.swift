public import AppKit
public import CmuxNextFileGrid
public import CmuxNextFiles
import Observation

/// The Screenshots pane: a source menu (all folders, or one), a name
/// filter, the file count, and the ``FileGridView`` of every screenshot and
/// recording, newest first. Drag tiles out to any app; drop files or
/// pictures in to save them into the macOS screenshot folder (or the
/// selected folder when it takes drops).
public final class ScreenshotsView: NSView {
    /// The pane's state.
    public let model: ScreenshotsModel
    /// The grid (the shared file-grid core).
    public let grid: FileGridView
    private let sourceMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let search = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let saver: ScreenshotDropSaver
    private let commands: ScreenshotsCommands
    private var shownSources: [ScreenshotSource] = []
    private static let headerHeight: CGFloat = 36
    /// Show Screenshots: up until the person clicks it, so a page an agent showed or a tab restored at launch
    /// reads no folder (macOS guards ~/Desktop, the default screenshot folder: LAUNCH-NO-TCC-PROMPTS).
    private let promptTitle = NSTextField(labelWithString: ScreenshotsStrings.promptTitle)
    private let promptBody = NSTextField(wrappingLabelWithString: ScreenshotsStrings.promptBody)
    private let promptButton = NSButton(title: ScreenshotsStrings.promptButton, target: nil, action: nil)
    private let prompt = NSStackView()

    /// The prompt title's color (the app passes its palette).
    public var primaryText: NSColor = .labelColor {
        didSet { promptTitle.textColor = primaryText }
    }

    /// Header text colors (the app passes its palette).
    public var secondaryText: NSColor = .secondaryLabelColor {
        didSet {
            count.textColor = secondaryText
            promptBody.textColor = secondaryText
        }
    }

    /// The prompt's fonts: the app passes its type scale (`Typography`); until then, the labels' own.
    public var promptFonts: (title: NSFont, body: NSFont)? {
        didSet {
            guard let promptFonts else { return }
            promptTitle.font = promptFonts.title
            promptBody.font = promptFonts.body
            promptButton.font = promptFonts.body
        }
    }

    /// Makes the pane view.
    ///
    /// - Parameters:
    ///   - model: the pane's state.
    ///   - cache: the app's thumbnail cache.
    ///   - workspace: opens and reveals files.
    ///   - files: copies drops in, renames and trashes (CmuxNextFiles).
    ///   - appearance: grid colors and tile size.
    public init(model: ScreenshotsModel, cache: ThumbnailCache, workspace: any ScreenshotsWorkspace,
                files: any FileOperating = FileOperator(), appearance: FileGridAppearance = FileGridAppearance()) {
        self.model = model
        self.grid = FileGridView(cache: cache, appearance: appearance)
        self.saver = ScreenshotDropSaver(files: files)
        self.commands = ScreenshotsCommands(workspace: workspace, files: files)
        super.init(frame: .zero)
        grid.onCommand = { [weak self] command, items in self?.commands.perform(command, on: items, in: self?.window) }
        sourceMenu.target = self
        sourceMenu.action = #selector(sourceChanged)
        sourceMenu.controlSize = .small
        sourceMenu.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        search.placeholderString = ScreenshotsStrings.filter
        search.focusRingType = .none
        search.controlSize = .small
        search.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = secondaryText
        count.alignment = .right
        grid.onDrop = { [weak self] pasteboard in self?.saveDrop(pasteboard) ?? false }
        configurePrompt()
        for view in [sourceMenu, search, count, grid, prompt] as [NSView] { addSubview(view) }
        setAccessibilityLabel(ScreenshotsStrings.title)
        refresh()
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let top = bounds.height - Self.headerHeight
        let controlHeight: CGFloat = 22
        let y = top + (Self.headerHeight - controlHeight) / 2
        let menuWidth = min(max(sourceMenu.intrinsicContentSize.width, 140), 260)
        sourceMenu.frame = CGRect(x: pad, y: y, width: menuWidth, height: controlHeight)
        let countWidth: CGFloat = 64
        count.frame = CGRect(x: bounds.width - pad - countWidth, y: y + 3, width: countWidth, height: controlHeight - 4)
        let searchX = sourceMenu.frame.maxX + 8
        search.frame = CGRect(x: searchX, y: y, width: max(80, count.frame.minX - 8 - searchX), height: controlHeight)
        grid.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, top))
        let promptWidth = min(max(0, bounds.width - 2 * pad), 360)
        promptBody.preferredMaxLayoutWidth = promptWidth
        let promptSize = prompt.fittingSize
        prompt.frame = CGRect(x: (bounds.width - promptWidth) / 2, y: (bounds.height - promptSize.height) / 2,
                              width: promptWidth, height: promptSize.height)
    }

    /// Runs when the person clicks Show Screenshots (the app remembers the tab and starts the folder detection).
    public var onShowScreenshots: (() -> Void)?

    /// Focuses the grid, or this pane while the prompt is up (the tab got focus): a plain button takes the keyboard
    /// only with Full Keyboard Access on, so the pane takes it and Space, the button's key, presses Show Screenshots.
    public func focus() {
        if showsPrompt { window?.makeFirstResponder(self) } else { grid.focus() }
    }

    /// The view that takes the keyboard when the tab is focused.
    public var focusTarget: NSView { showsPrompt ? self : grid }

    public override var acceptsFirstResponder: Bool { showsPrompt }

    public override func keyDown(with event: NSEvent) {
        guard showsPrompt, event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            return super.keyDown(with: event)
        }
        showScreenshots()
    }

    /// Whether the Show Screenshots prompt is up (the page has listed nothing yet).
    public var showsPrompt: Bool { !prompt.isHidden }

    /// The person's click on Show Screenshots: the page lists its folders from now on. The prompt goes in one
    /// frame, with no animation.
    @objc public func showScreenshots() {
        let hadKeyboard = window?.firstResponder === self || window?.firstResponder === promptButton
        model.startListing()
        onShowScreenshots?()
        refresh()
        if hadKeyboard { grid.focus() } // the keyboard goes on to the grid that replaced the prompt
    }

    private func configurePrompt() {
        promptTitle.alignment = .center
        promptBody.alignment = .center
        promptBody.textColor = secondaryText
        promptButton.target = self
        promptButton.action = #selector(showScreenshots)
        promptButton.bezelStyle = .push
        prompt.orientation = .vertical
        prompt.alignment = .centerX
        prompt.spacing = 8
        for view in [promptTitle, promptBody, promptButton] as [NSView] { prompt.addArrangedSubview(view) }
        prompt.setCustomSpacing(14, after: promptBody)
    }

    // MARK: State

    private func observe() {
        withObservationTracking {
            _ = model.visibleItems
            _ = model.sources
            _ = model.unreadableSourceIDs
            _ = model.isListing
        } onChange: { [weak self] in
            // task-owner: one main-actor hop per model change; the view re-arms the observation.
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
    }

    private func refresh() {
        let gated = !model.isListing
        prompt.isHidden = !gated
        for view in [sourceMenu, search, count, grid] as [NSView] { view.isHidden = gated }
        let items = model.visibleItems
        grid.show(items)
        grid.emptyText = model.listing.count == 0 ? ScreenshotsStrings.empty : ScreenshotsStrings.noMatches
        count.stringValue = items.count.formatted()
        rebuildSourceMenu()
    }

    private func rebuildSourceMenu() {
        let counts = model.listing.countsBySource
        shownSources = model.sources
        let menu = NSMenu()
        let all = NSMenuItem(title: "\(ScreenshotsStrings.allSources) (\(model.listing.count.formatted()))", action: nil, keyEquivalent: "")
        menu.addItem(all)
        menu.addItem(.separator())
        for source in shownSources {
            let unreadable = model.unreadableSourceIDs.contains(source.id)
            let title = unreadable ? ScreenshotsStrings.unreadable(source.label) : "\(source.label) (\((counts[source.id] ?? 0).formatted()))"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.toolTip = source.folder.path
            item.representedObject = source.id
            menu.addItem(item)
        }
        sourceMenu.menu = menu
        if let selected = model.selectedSourceID, let index = menu.items.firstIndex(where: { ($0.representedObject as? String) == selected }) {
            sourceMenu.selectItem(at: index)
        } else {
            sourceMenu.selectItem(at: 0)
        }
        needsLayout = true
    }

    @objc private func sourceChanged() {
        model.selectedSourceID = sourceMenu.selectedItem?.representedObject as? String
    }

    @objc private func searchChanged() {
        model.query = search.stringValue
    }

    /// Saves a drop into ``ScreenshotsModel/dropDestination`` (through CmuxNextFiles) and selects the
    /// first saved file. The drop is read at once; the copy runs after the drag ends.
    private func saveDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard let folder = model.dropDestination, saver.canSave(pasteboard) else { return false }
        let drop = ScreenshotDropValue(droppedFileURLs: pasteboard.droppedFileURLs,
                                       droppedImage: pasteboard.droppedFileURLs.isEmpty ? pasteboard.droppedImage : nil)
        let saver = saver
        // task-owner: one drop's save; ends when the files are copied in
        Task { @MainActor [weak self] in
            do {
                let saved = try await saver.save(drop, into: folder)
                await self?.model.noteSaved(saved)
                self?.refresh()
                if let first = saved.first { self?.grid.reveal(path: first.path) }
            } catch {
                // dialog-keys-exempt: CmuxNextScreenshots reaches no CmuxDialogCenter (it depends on CmuxNextFileGrid and CmuxNextFiles only); move to a dialog seam with the Finder pane
                let alert = NSAlert(error: error)
                alert.messageText = ScreenshotsStrings.dropFailed
                if let window = self?.window { alert.beginSheetModal(for: window, completionHandler: nil) }
            }
        }
        return true
    }
}
