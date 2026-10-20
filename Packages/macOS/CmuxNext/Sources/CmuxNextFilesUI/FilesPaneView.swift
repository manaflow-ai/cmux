public import AppKit
public import CmuxNextFiles
import CmuxNextCompat
import CmuxNextDesign
public import Quartz

/// A Files pane: toolbar (Back, Forward, Enclosing Folder, path bar, layout,
/// filter), the folder in list, icon or column layout, and a status line.
///
/// Built from a ``FileBrowserModel`` the host owns; the host also says how a
/// file opens (a cmux viewer or the default app):
///
/// ```swift
/// let model = FileBrowserModel(folder: FileManager.default.homeDirectoryForCurrentUser)
/// let pane = FilesPaneView(model: model, icons: icons) { url in NSWorkspace.shared.open(url) }
/// ```
@MainActor
public final class FilesPaneView: NSView {
    let model: FileBrowserModel
    let icons: FileIconProvider
    let openFile: (URL) -> Void
    let quickLook = QuickLookSource()
    lazy var prompts = FilesPrompts(window: { [weak self] in self?.window })
    private let toolbar = NSStackView()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let pathControl = NSPathControl()
    private let layoutControl = NSSegmentedControl()
    private let filterField = NSSearchField()
    private let content = NSView()
    private let status = NSTextField(labelWithString: "")
    private var views: [FileViewMode: any FileContentView] = [:]
    private var shown: (any FileContentView)?
    private var observation: Task<Void, Never>?

    /// Makes a pane over `model` and starts showing it.
    /// - Parameters:
    ///   - model: The pane's state (the host keeps it for history and restore).
    ///   - icons: Shared icon and thumbnail cache.
    ///   - openFile: Opens a file the person activated.
    public init(model: FileBrowserModel, icons: FileIconProvider, openFile: @escaping (URL) -> Void) {
        self.model = model
        self.icons = icons
        self.openFile = openFile
        super.init(frame: .zero)
        buildChrome()
        observation = Task { [weak self] in
            guard let model = self?.model else { return }
            for await _ in ObservationStream({ [model] in
                _ = (model.entries, model.selection, model.folder, model.viewMode, model.phase, model.canGoBack,
                     model.canGoForward, model.showHidden, model.transferProgress, model.lastError)
            }) {
                self?.render()
            }
        }
        if model.phase != .ready { Task { await model.reload() } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Stops observing and watching (the tab closed).
    public func stop() {
        observation?.cancel()
        model.stop()
    }

    override public var acceptsFirstResponder: Bool { true }

    override public func becomeFirstResponder() -> Bool {
        if let focus = shown?.focusView { return window?.makeFirstResponder(focus) ?? false }
        return super.becomeFirstResponder()
    }

    /// The pane's tab title when no folder is known ("Files", localized).
    public nonisolated static var paneTitle: String { FilesStrings.title }
    /// The word Duplicate adds to names ("copy", localized as Finder does).
    public nonisolated static var copyWord: String { FilesStrings.copyWord }

    var currentContent: (any FileContentView)? { shown }
    var filterFieldForFocus: NSView { filterField }

    /// The view keyboard focus goes to (the current layout's list).
    public var focusTarget: NSView { shown?.focusView ?? self }

    // MARK: Rendering

    private func render() {
        let view = contentView(for: model.viewMode)
        if shown !== view {
            shown?.view.removeFromSuperview()
            view.view.frame = content.bounds
            view.view.autoresizingMask = [.width, .height]
            content.addSubview(view.view)
            shown = view
        }
        (view as? FileColumnsView)?.setShowsHidden(model.showHidden)
        view.show(model.entries, of: model.folder, selection: model.selection)
        backButton.isEnabled = model.canGoBack
        forwardButton.isEnabled = model.canGoForward
        upButton.isEnabled = model.canGoUp
        if pathControl.url != model.folder { pathControl.url = model.folder }
        layoutControl.selectedSegment = FileViewMode.allCases.firstIndex(of: model.viewMode) ?? 1
        if filterField.stringValue != model.filterText { filterField.stringValue = model.filterText }
        status.stringValue = statusText()
        quickLook.urls = model.selectedEntries.map(\.url)
        quickLook.refresh()
    }

    private func statusText() -> String {
        if let progress = model.transferProgress {
            return FilesStrings.copying(progress.itemsTotal) + " " + String(format: "%.0f%%", progress.fraction * 100)
        }
        switch model.phase {
        case .loading: return FilesStrings.loading
        case .failed(let message): return FilesStrings.cannotOpen + " " + message
        case .ready:
            if model.entries.isEmpty { return FilesStrings.empty }
            if model.selection.isEmpty { return FilesStrings.items(model.entries.count) }
            return FilesStrings.selected(model.selection.count, of: model.entries.count)
        }
    }

    private func contentView(for mode: FileViewMode) -> any FileContentView {
        if let made = views[mode] { return made }
        let actions = makeActions()
        let made: any FileContentView = switch mode {
        case .list: FileListView(actions: actions, icons: icons)
        case .icons: FileIconGridView(actions: actions, icons: icons)
        case .columns: FileColumnsView(actions: actions, icons: icons, lister: DirectoryLister())
        }
        views[mode] = made
        return made
    }

    // MARK: Chrome

    private func buildChrome() {
        for (button, symbol, label, action) in [
            (backButton, "chevron.left", FilesStrings.back, #selector(goBack)),
            (forwardButton, "chevron.right", FilesStrings.forward, #selector(goForward)),
            (upButton, "arrow.up", FilesStrings.enclosingFolder, #selector(goUp)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.toolTip = label
            button.target = self
            button.action = action
        }
        pathControl.pathStyle = .standard
        pathControl.target = self
        pathControl.action = #selector(pathClicked)
        pathControl.registerForDraggedTypes([.fileURL])
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        layoutControl.segmentCount = FileViewMode.allCases.count
        for (index, mode) in FileViewMode.allCases.enumerated() {
            let (symbol, label) = switch mode {
            case .icons: ("square.grid.2x2", FilesStrings.viewIcons)
            case .list: ("list.bullet", FilesStrings.viewList)
            case .columns: ("rectangle.split.3x1", FilesStrings.viewColumns)
            }
            layoutControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: index)
            layoutControl.setToolTip(label, forSegment: index)
        }
        layoutControl.segmentStyle = .separated
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged)
        filterField.placeholderString = FilesStrings.filter
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.sendsSearchStringImmediately = true
        filterField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        toolbar.orientation = .horizontal
        toolbar.spacing = Metrics.space2
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        for view in [backButton, forwardButton, upButton, pathControl, layoutControl, filterField] as [NSView] { toolbar.addArrangedSubview(view) }
        status.font = Typography.system(size: TypeScale.caption)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        for view in [toolbar, content, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            status.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 2),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @objc private func goBack() { Task { await model.goBack() } }
    @objc private func goForward() { Task { await model.goForward() } }
    @objc private func goUp() { Task { await model.goUp() } }
    @objc private func pathClicked() {
        guard let url = pathControl.clickedPathItem?.url else { return }
        Task { await model.open(url) }
    }
    @objc private func layoutChanged() {
        let modes = FileViewMode.allCases
        if layoutControl.selectedSegment >= 0, layoutControl.selectedSegment < modes.count {
            model.viewMode = modes[layoutControl.selectedSegment]
            window?.makeFirstResponder(focusTarget)
        }
    }
    @objc private func filterChanged() { model.filterText = filterField.stringValue }

    // MARK: Quick Look (responder chain)

    override nonisolated public func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // QLPreviewPanel calls these on the main thread (it is an AppKit panel).
    override nonisolated public func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = quickLook
            panel.delegate = quickLook
            quickLook.onKey = { [weak self] event in self?.handleQuickLookKey(event) ?? false }
        }
    }

    override nonisolated public func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}
