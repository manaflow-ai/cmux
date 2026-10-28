public import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextFileGrid
public import CmuxNextFiles
public import CmuxNextWakeups

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
    /// The pane's place in the visibility tree: its tab hides it (`setContentVisible`), so a hidden pane reads
    /// no model change and shows the latest once, on show.
    private let visibility = ViewVisibility("screenshots")
    private var visibilityNode: VisibilityNode { visibility.node }
    /// The grid and header follow the model while the pane shows (R-obs).
    private var modelWatch: VisibleObservation<ObservationTrigger<Int>>?
    /// How many times the grid and header were refreshed from the model (tests).
    private(set) var refreshes = 0

    /// Header text colors (the app passes its palette).
    public var secondaryText: NSColor = .secondaryLabelColor {
        didSet { count.textColor = secondaryText }
    }

    /// Makes the pane view.
    ///
    /// - Parameters:
    ///   - model: the pane's state.
    ///   - cache: the app's thumbnail cache.
    ///   - workspace: opens and reveals files.
    ///   - files: copies drops in, renames and trashes (CmuxNextFiles).
    ///   - appearance: grid colors and tile size.
    ///   - mainWork: the app's one main-thread scheduler (the grid follows the model on it, and its thumbnails land on it).
    public init(model: ScreenshotsModel, cache: ThumbnailCache, workspace: any ScreenshotsWorkspace,
                files: any FileOperating = FileOperator(), appearance: FileGridAppearance = FileGridAppearance(),
                mainWork: MainWorkScheduler) {
        self.model = model
        self.grid = FileGridView(cache: cache, work: mainWork, appearance: appearance)
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
        for view in [sourceMenu, search, count, grid] as [NSView] { addSubview(view) }
        setAccessibilityLabel(ScreenshotsStrings.title)
        // R-obs: the grid, the count and the source menu are views, so they follow the model only while the pane
        // shows; the first value applies now.
        modelWatch = VisibleObservation(visibilityNode, owner: Self.modelOwner, on: mainWork) {
            _ = model.visibleItems
            _ = model.sources
            return ObservationTrigger(model.unreadableSourceIDs.count)
        } apply: { [weak self] _ in
            self?.refresh()
        }
    }

    /// The model observation's owner in the board and the wakeup ledger.
    static let modelOwner = "ScreenshotsView.model"

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
    }

    /// Focuses the grid (the tab got focus).
    public func focus() { grid.focus() }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility.place(in: window)
    }

    // R-hide: hiding forwards to the node (the page tab hides the pane when its tab is not shown).
    public override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
    }

    // MARK: State

    private func refresh() {
        refreshes += 1
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
        // main-hop-allow: a person's drop: the saver copies off main (CmuxNextFiles), and its end selects the saved file or shows the failure sheet on this pane's window
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
