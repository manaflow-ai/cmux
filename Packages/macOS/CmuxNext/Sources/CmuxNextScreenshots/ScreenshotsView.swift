public import AppKit
public import CmuxNextFileGrid
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
    private let importer = FileGridDropImporter()
    private var shownSources: [ScreenshotSource] = []
    private static let headerHeight: CGFloat = 36

    /// Header text colors (the app passes its palette).
    public var secondaryText: NSColor = .secondaryLabelColor {
        didSet { count.textColor = secondaryText }
    }

    /// Makes the pane view.
    ///
    /// - Parameters:
    ///   - model: the pane's state.
    ///   - cache: the app's thumbnail cache.
    ///   - workspace: opens, reveals and trashes files.
    ///   - appearance: grid colors and tile size.
    public init(model: ScreenshotsModel, cache: ThumbnailCache, workspace: any FileGridWorkspace,
                appearance: FileGridAppearance = FileGridAppearance()) {
        self.model = model
        self.grid = FileGridView(cache: cache, appearance: appearance, workspace: workspace)
        super.init(frame: .zero)
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
    }

    /// Focuses the grid (the tab got focus).
    public func focus() { grid.focus() }

    // MARK: State

    private func observe() {
        withObservationTracking {
            _ = model.visibleItems
            _ = model.sources
            _ = model.unreadableSourceIDs
        } onChange: { [weak self] in
            // task-owner: one main-actor hop per model change; the view re-arms the observation.
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
    }

    private func refresh() {
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

    /// Saves a drop into ``ScreenshotsModel/dropDestination`` and selects the first saved file.
    private func saveDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard let folder = model.dropDestination else { return false }
        do {
            let saved = try importer.importItems(from: pasteboard, into: folder)
            guard !saved.isEmpty else { return false }
            // task-owner: adds the saved files at once; the folder watch confirms them.
            Task { [weak self] in
                await self?.model.noteSaved(saved)
                self?.refresh()
                if let first = saved.first { self?.grid.reveal(path: first.path) }
            }
            return true
        } catch {
            // dialog-keys-exempt: CmuxNextScreenshots depends only on the system-frameworks-only CmuxNextFileGrid, so it cannot reach CmuxDialogCenter
            let alert = NSAlert(error: error)
            alert.messageText = ScreenshotsStrings.dropFailed
            if let window { alert.beginSheetModal(for: window) }
            return false
        }
    }
}
