public import AppKit
public import CmuxNextFiles
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextWakeups
public import Quartz

/// A Files pane: toolbar (Back, Forward, Enclosing Folder, path bar, layout,
/// filter), the folder in list, icon or column layout, and a status line.
///
/// Built from a ``FileBrowserModel`` the host owns; the host also says how a
/// file opens (a cmux viewer or the default app):
///
/// ```swift
/// let model = FileBrowserModel(folder: FileManager.default.homeDirectoryForCurrentUser, work: mainWork)
/// let sidebar = SidebarModel(home: home, defaults: .standard)
/// let pane = FilesPaneView(model: model, sidebar: sidebar, icons: icons, mainWork: services.mainWork) { url in
///     NSWorkspace.shared.openInBackground(url)
/// }
/// ```
@MainActor
public final class FilesPaneView: NSView {
    let model: FileBrowserModel
    let icons: FileIconProvider
    let openFile: (URL) -> Void
    let sidebar: SidebarModel
    let home: URL
    var infoWindows: [URL: FileInfoWindow] = [:]
    private lazy var sidebarView = FileSidebarView(actions: makeSidebarActions())
    private var sidebarWidth: NSLayoutConstraint?
    let quickLook = QuickLookSource()
    /// The shared file menu (Open With, Share) the host gives; nil leaves those rows out.
    public var fileMenu: FileActionsMenu?
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
    let zoomSlider = NSSlider(value: 96, minValue: 32, maxValue: 256, target: nil, action: nil)
    private var available: (folder: URL, bytes: Int64?)?
    private var views: [FileViewMode: any FileContentView] = [:]
    private var shown: (any FileContentView)?
    /// The icon arrivals the shown view has drawn (``FileIconProvider/arrivals``).
    private var drawnIconArrivals = 0
    /// Renders the pane: only while it is on screen, once on show (made in `init`).
    private var observation: VisibleObservation<Void>?
    /// The app's main-thread scheduler: the pane's render and its replies from off main run on it.
    let mainWork: MainWorkScheduler
    /// This pane in the visibility tree: an unselected tab, a hidden pane or an occluded window renders nothing.
    let visibility = ViewVisibility("filesPane")
    var visibilityNode: VisibilityNode { visibility.node }

    /// Makes a pane over `model` and starts showing it.
    /// - Parameters:
    ///   - model: The pane's state (the host keeps it for history and restore).
    ///   - sidebar: Favorites and Locations (one model shared by every Files pane).
    ///   - icons: Shared icon and thumbnail cache.
    ///   - home: The person's home folder (Go menu, sidebar symbols).
    ///   - mainWork: The app's main-thread scheduler.
    ///   - openFile: Opens a file the person activated.
    public init(model: FileBrowserModel, sidebar: SidebarModel, icons: FileIconProvider,
                home: URL = FileManager.default.homeDirectoryForCurrentUser, mainWork: MainWorkScheduler,
                openFile: @escaping (URL) -> Void) {
        self.model = model
        self.sidebar = sidebar
        self.icons = icons
        self.home = home
        self.mainWork = mainWork
        self.openFile = openFile
        super.init(frame: .zero)
        buildChrome()
        // The render touches only this pane's views: a VisibleObservation on its node. A person's Back or
        // double-click renders before its commit; a listing that lands renders once per frame.
        observation = VisibleObservation(visibilityNode, owner: "FilesPane.render", on: mainWork) { [model, sidebar, icons] in
            _ = (model.entries, model.selection, model.folder, model.viewMode, model.phase, model.canGoBack,
                 model.canGoForward, model.showHidden, model.transferProgress, model.lastError,
                 sidebar.favorites, sidebar.locations, sidebar.isVisible, icons.arrivals)
        } apply: { [weak self] _ in
            self?.render()
        }
        if model.phase != .ready { navigate { await $0.reload() } }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility.place(in: window)
    }

    override public func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
    }

    /// Starts a navigation of `model` (a toolbar click, the path bar, the first listing). FileBrowserModel's
    /// navigations are main-actor: each changes the folder in its first step and lists off main.
    private func navigate(_ step: @escaping @MainActor (FileBrowserModel) async -> Void) {
        let model = model
        // task-owner: one navigation; ends when its listing lands
        // main-hop-allow: the person's click starts FileBrowserModel's main-actor navigation, whose listing runs off main; post has no async form
        Task { await step(model) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Stops observing and watching (the tab closed).
    public func stop() {
        observation?.cancel()
        for window in infoWindows.values { window.panel.close() }
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
    /// The word Make Alias adds to names ("alias", localized as Finder does).
    public nonisolated static var aliasWord: String { FilesStrings.aliasWord }

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
        if drawnIconArrivals != icons.arrivals {
            drawnIconArrivals = icons.arrivals
            view.redrawIcons()
        }
        sidebarView.view.isHidden = !sidebar.isVisible
        sidebarWidth?.constant = sidebar.isVisible ? 170 : 0
        if sidebar.isVisible { sidebarView.show(FileSidebarRow.rows(for: sidebar, home: home), current: model.folder) }
        backButton.isEnabled = model.canGoBack
        forwardButton.isEnabled = model.canGoForward
        upButton.isEnabled = model.canGoUp
        if pathControl.url != model.folder { pathControl.url = model.folder }
        layoutControl.selectedSegment = FileViewMode.allCases.firstIndex(of: model.viewMode) ?? 1
        if filterField.stringValue != model.filterText { filterField.stringValue = model.filterText }
        status.stringValue = statusText()
        zoomSlider.isHidden = model.viewMode != .icons
        if available?.folder != model.folder { loadAvailable(model.folder) }
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
            let free = available?.bytes.map { FilesStrings.available(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) }
            let counts = model.entries.isEmpty ? FilesStrings.empty
                : model.selection.isEmpty ? FilesStrings.items(model.entries.count)
                : FilesStrings.selected(model.selection.count, of: model.entries.count)
            return [counts, free].compactMap { $0 }.joined(separator: ", ")
        }
    }

    private func loadAvailable(_ folder: URL) {
        available = (folder, nil)
        let land: @MainActor @Sendable (Int64?) -> Void = { [weak self] bytes in
            guard let self, self.available?.folder == folder else { return }
            self.available = (folder, bytes)
            self.status.stringValue = self.statusText()
        }
        let mainWork = mainWork
        // task-owner: one volume read off main; ends when the status line shows it
        Task { @concurrent in
            let bytes = await FileInfoReader().availableCapacity(of: folder)
            // node-free: one status label write of the folder the pane rendered last; a hidden pane re-renders on show anyway
            mainWork.postFromAnyThread(.visible, owner: "FilesPane.available") { land(bytes) }
        }
    }

    private func contentView(for mode: FileViewMode) -> any FileContentView {
        if let made = views[mode] { return made }
        let actions = makeActions()
        let made: any FileContentView = switch mode {
        case .list: FileListView(actions: actions, icons: icons)
        case .icons: FileIconGridView(actions: actions, icons: icons, tileSize: CGFloat(zoomSlider.doubleValue))
        case .columns: FileColumnsView(actions: actions, icons: icons, lister: DirectoryLister(), mainWork: mainWork)
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
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = action
        }
        // Back and forward are plain chevrons; only "up" says where it goes.
        upButton.themedToolTip = FilesStrings.enclosingFolder
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
        }
        layoutControl.segmentStyle = .separated
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged)
        filterField.placeholderString = FilesStrings.filter
        filterField.focusRingType = .none
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
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged)
        zoomSlider.controlSize = .small
        zoomSlider.themedToolTip = FilesStrings.iconSize
        for view in [toolbar, sidebarView.view, content, status, zoomSlider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            sidebarView.view.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            sidebarView.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarView.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: sidebarView.view.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            status.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 2),
            status.leadingAnchor.constraint(equalTo: sidebarView.view.trailingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: zoomSlider.leadingAnchor, constant: -8),
            zoomSlider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            zoomSlider.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            zoomSlider.widthAnchor.constraint(equalToConstant: 100),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        let width = sidebarView.view.widthAnchor.constraint(equalToConstant: 170)
        width.isActive = true
        sidebarWidth = width
    }

    @objc private func goBack() { navigate { await $0.goBack() } }
    @objc private func goForward() { navigate { await $0.goForward() } }
    @objc private func goUp() { navigate { await $0.goUp() } }
    @objc private func pathClicked() {
        guard let url = pathControl.clickedPathItem?.url else { return }
        navigate { await $0.open(url) }
    }
    @objc private func layoutChanged() {
        let modes = FileViewMode.allCases
        if layoutControl.selectedSegment >= 0, layoutControl.selectedSegment < modes.count {
            model.viewMode = modes[layoutControl.selectedSegment]
            window?.makeFirstResponder(focusTarget)
        }
    }
    @objc private func zoomChanged() { setIconSize(CGFloat(zoomSlider.doubleValue)) }

    /// Sets the icon layout's tile size (slider, Cmd+= / Cmd+-), 32 to 256 points.
    func setIconSize(_ size: CGFloat) {
        let clamped = min(256, max(32, size))
        zoomSlider.doubleValue = Double(clamped)
        (views[.icons] as? FileIconGridView)?.tileSize = clamped
    }

    @objc private func filterChanged() { model.filterText = filterField.stringValue }

    // MARK: Quick Look (responder chain)

    override nonisolated public func acceptsPreviewPanelControl(_ panel: QLPreviewPanel?) -> Bool { true }

    // QLPreviewPanel calls these on the main thread (it is an AppKit panel); off main (never
    // seen) the change hops there instead of trapping.
    override nonisolated public func beginPreviewPanelControl(_ panel: QLPreviewPanel?) {
        guard let panel else { return }
        // main-hop-allow: QLPreviewPanel calls on main (AppKit); this off-main branch is a never-seen fallback that hops instead of trapping
        guard Thread.isMainThread else { Task { @MainActor in attachQuickLook(panel, true) }; return }
        MainActor.assumeIsolated { attachQuickLook(panel, true) } // main-proof: checked Thread.isMainThread above
    }

    override nonisolated public func endPreviewPanelControl(_ panel: QLPreviewPanel?) {
        guard let panel else { return }
        // main-hop-allow: as in beginPreviewPanelControl: a never-seen off-main fallback
        guard Thread.isMainThread else { Task { @MainActor in attachQuickLook(panel, false) }; return }
        MainActor.assumeIsolated { attachQuickLook(panel, false) } // main-proof: checked Thread.isMainThread above
    }

    private func attachQuickLook(_ panel: QLPreviewPanel, _ on: Bool) {
        panel.dataSource = on ? quickLook : nil
        panel.delegate = on ? quickLook : nil
        if on { quickLook.onKey = { [weak self] event in self?.handleQuickLookKey(event) ?? false } }
    }
}
