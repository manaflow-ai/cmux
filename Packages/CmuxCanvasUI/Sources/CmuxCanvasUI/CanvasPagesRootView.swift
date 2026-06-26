public import AppKit
import CmuxCanvas

/// Native AppKit page-strip host for the Pages workspace layout.
@MainActor
public final class CanvasPagesRootView: NSView {
    let model: CanvasModel
    let callbacks: CanvasHostCallbacks
    private let themeProvider: () -> CanvasTheme
    let pageController = NSPageController()
    private var descriptorsByPanelId: [UUID: CanvasPaneDescriptor] = [:]
    var pageObjects: [CanvasPageObject] = []
    private var viewControllers: [NSPageController.ObjectIdentifier: CanvasPageViewController] = [:]
    var latestFocusedPanelId: UUID?
    var selectedPaneID: CanvasPaneID?
    private var isWorkspaceVisible = true
    var isApplyingSyncSelection = false
    var pageScrollMonitor: Any?
    private var renderingUpdateTask: Task<Void, Never>?
    private var publishedRenderedPanelIds: Set<UUID> = []

    /// Creates a native Pages root view.
    ///
    /// - Parameters:
    ///   - model: The durable canvas pane/tab model owned by the workspace.
    ///   - callbacks: Host callbacks for focus, close, and layout events.
    ///   - themeProvider: Supplies current page and pane colors.
    public init(
        model: CanvasModel,
        callbacks: CanvasHostCallbacks,
        themeProvider: @escaping () -> CanvasTheme
    ) {
        self.model = model
        self.callbacks = callbacks
        self.themeProvider = themeProvider
        super.init(frame: .zero)

        pageController.transitionStyle = .horizontalStrip
        pageController.delegate = self
        pageController.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pageController.view)
        NSLayoutConstraint.activate([
            pageController.view.topAnchor.constraint(equalTo: topAnchor),
            pageController.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            pageController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            pageController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        wantsLayer = true
        applyTheme()
        model.viewport = self
    }

    /// Interface Builder initialization is unavailable for this programmatic host view.
    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    var currentTheme: CanvasTheme {
        themeProvider()
    }

    var shouldRenderPreparedPages: Bool {
        isWorkspaceVisible
    }

    private func applyTheme() {
        layer?.backgroundColor = currentTheme.canvasBackground.cgColor
        for controller in viewControllers.values {
            if let page = controller.currentPageObject {
                controller.prepare(page: page, owner: self)
            }
        }
    }

    /// Reapplies page colors when AppKit reports an appearance change.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    /// Reconciles mounted page rendering after AppKit assigns page-controller child geometry.
    public override func layout() {
        super.layout()
        reconcileRenderingAfterLayout()
    }

    func reconcileRenderingAfterLayout(requiresWindow: Bool = true) {
        pageController.view.layoutSubtreeIfNeeded()
        updateControllerRendering(requiresWindow: requiresWindow)
    }

    /// Installs or removes the local scroll monitor as the view enters or leaves a window.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removePageScrollMonitor()
            updateControllerRendering()
        } else {
            installPageScrollMonitor()
            scheduleRenderingUpdate()
        }
    }

    /// Reconciles the native page strip against the host's current panels.
    public func sync(
        descriptors: [CanvasPaneDescriptor],
        focusedPanelId: UUID?,
        isWorkspaceVisible: Bool
    ) {
        let previousFocusedPanelId = latestFocusedPanelId
        self.isWorkspaceVisible = isWorkspaceVisible
        latestFocusedPanelId = focusedPanelId
        model.syncPanes(panelIds: descriptors.map(\.id), focusedPanelId: focusedPanelId)
        if let focusedPanelId, model.paneID(containing: focusedPanelId) != nil {
            model.selectPanel(focusedPanelId)
        }
        descriptorsByPanelId = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

        let previousPaneID = selectedPaneID
        pageObjects = orderedPageObjects(from: model.layout)
        pageController.arrangedObjects = pageObjects

        guard !pageObjects.isEmpty else {
            selectedPaneID = nil
            refreshPreparedControllers()
            callbacks.onViewportGeometryChanged(window)
            return
        }

        let focusedIndex = indexForPanel(focusedPanelId)
        let shouldFollowFocus = previousPaneID == nil || focusedPanelId != previousFocusedPanelId
        let targetIndex = (shouldFollowFocus ? focusedIndex : nil)
            ?? previousPaneID.flatMap(indexForPane)
            ?? focusedIndex
            ?? min(max(pageController.selectedIndex, 0), pageObjects.count - 1)
        selectPage(at: targetIndex, animated: false, suppressFocus: true)
        refreshPreparedControllers()
        callbacks.onViewportGeometryChanged(window)
    }

    /// Releases mounted panel content and disconnects from the model.
    public func teardown() {
        for controller in viewControllers.values {
            controller.teardown()
        }
        renderingUpdateTask?.cancel()
        renderingUpdateTask = nil
        viewControllers.removeAll()
        pageController.delegate = nil
        descriptorsByPanelId.removeAll()
        pageObjects.removeAll()
        removePageScrollMonitor()
        if model.viewport === self {
            model.viewport = nil
        }
    }

    func descriptor(for panelId: UUID) -> CanvasPaneDescriptor? {
        descriptorsByPanelId[panelId]
    }

    func chrome(for pane: CanvasPane) -> CanvasPaneChrome {
        let tabs = pane.panelIds.compactMap { descriptorsByPanelId[$0.rawValue]?.tab }
        let isFocused = pane.panelIds.contains { descriptorsByPanelId[$0.rawValue]?.isFocused == true }
        let closeLabel = descriptorsByPanelId[pane.selectedPanelId.rawValue]?.closeActionLabel
            ?? descriptorsByPanelId.values.first?.closeActionLabel
            ?? ""
        return CanvasPaneChrome(
            tabs: tabs,
            selectedTabId: pane.selectedPanelId.rawValue,
            isFocused: isFocused,
            closeActionLabel: closeLabel
        )
    }

    func identifier(for page: CanvasPageObject) -> NSPageController.ObjectIdentifier {
        NSPageController.ObjectIdentifier("canvas.page.\(page.paneID.rawValue.uuidString)")
    }

    func register(_ controller: CanvasPageViewController, for page: CanvasPageObject?) {
        let staleIdentifiers = viewControllers.compactMap { identifier, existing in
            existing === controller ? identifier : nil
        }
        for identifier in staleIdentifiers {
            viewControllers.removeValue(forKey: identifier)
        }

        guard let page else { return }
        let identifier = identifier(for: page)
        if let existing = viewControllers[identifier], existing !== controller {
            existing.teardown()
        }
        viewControllers[identifier] = controller
    }

    func selectTab(_ panelId: UUID) {
        model.selectPanel(panelId)
        callbacks.onLayoutChanged()
        callbacks.onFocusPanel(panelId)
        modelDidChangeExternally(animated: false)
    }

    func closeTab(_ panelId: UUID) {
        callbacks.onClosePanel(panelId)
    }

    func focusPage(for paneID: CanvasPaneID) {
        guard let pane = model.layout.panes.first(where: { $0.id == paneID }) else { return }
        callbacks.onFocusPanel(pane.selectedPanelId.rawValue)
    }

    func selectedPageObject() -> CanvasPageObject? {
        guard pageController.selectedIndex >= 0,
              pageController.selectedIndex < pageObjects.count else {
            return nil
        }
        return pageObjects[pageController.selectedIndex]
    }

    func mountedPageObjects() -> [CanvasPageObject] {
        viewControllers.values.compactMap(\.currentPageObject)
    }

    func renderedPageObjects(requiresWindow: Bool = true) -> [CanvasPageObject] {
        viewControllers.values.compactMap { controller in
            isRendering(controller, requiresWindow: requiresWindow) ? controller.currentPageObject : nil
        }
    }

    func renderedPagePanelIds(requiresWindow: Bool = true) -> Set<UUID> {
        Set(renderedPageObjects(requiresWindow: requiresWindow).map(\.selectedPanelId))
    }

    func indexForPanel(_ panelId: UUID?) -> Int? {
        guard let panelId,
              let paneID = model.paneID(containing: panelId) else {
            return nil
        }
        return indexForPane(paneID)
    }

    func indexForPane(_ paneID: CanvasPaneID) -> Int? {
        pageObjects.firstIndex(where: { $0.paneID == paneID })
    }

    func selectPage(at index: Int, animated: Bool, suppressFocus: Bool) {
        guard index >= 0, index < pageObjects.count else { return }
        selectedPaneID = pageObjects[index].paneID
        guard pageController.selectedIndex != index else { return }
        if animated && !suppressFocus {
            pageController.animator().selectedIndex = index
            return
        }
        // Suppressed model-sync selections must not depend on AppKit animation callbacks.
        let wasApplyingSyncSelection = isApplyingSyncSelection
        isApplyingSyncSelection = suppressFocus
        pageController.selectedIndex = index
        isApplyingSyncSelection = wasApplyingSyncSelection
    }

    func finishSelection(of object: CanvasPageObject) {
        selectedPaneID = object.paneID
        refreshPreparedControllers()
        guard !isApplyingSyncSelection else { return }
        callbacks.onFocusPanel(object.selectedPanelId)
        callbacks.onViewportSettled(window)
    }

    func refreshPreparedControllers() {
        let pagesByPaneID = Dictionary(uniqueKeysWithValues: pageObjects.map { ($0.paneID, $0) })
        let retainedPaneIDs = preparedPaneIDs()
        for (identifier, controller) in viewControllers {
            guard let current = controller.currentPageObject,
                  retainedPaneIDs.contains(current.paneID),
                  let page = pagesByPaneID[current.paneID] else {
                controller.teardown()
                viewControllers.removeValue(forKey: identifier)
                continue
            }
            controller.prepare(page: page, owner: self)
        }
        scheduleRenderingUpdate()
    }

    func preparedPaneIDs() -> Set<CanvasPaneID> {
        guard !pageObjects.isEmpty else { return [] }
        let selectedIndex = selectedPaneID.flatMap(indexForPane)
            ?? min(max(pageController.selectedIndex, 0), pageObjects.count - 1)
        let lowerBound = max(0, selectedIndex - 1)
        let upperBound = min(pageObjects.count - 1, selectedIndex + 1)
        var paneIDs = Set(pageObjects[lowerBound...upperBound].map(\.paneID))
        for controller in viewControllers.values where controller.isRendered(in: pageController.view, requiresWindow: false) {
            if let page = controller.currentPageObject {
                paneIDs.insert(page.paneID)
            }
        }
        return paneIDs
    }

    func scheduleRenderingUpdate() {
        renderingUpdateTask?.cancel()
        renderingUpdateTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            updateControllerRendering()
        }
    }

    func updateControllerRendering(requiresWindow: Bool = true) {
        for controller in viewControllers.values {
            controller.setRendering(isRendering(controller, requiresWindow: requiresWindow))
        }
        let renderedPanelIds = renderedPagePanelIds(requiresWindow: requiresWindow)
        guard renderedPanelIds != publishedRenderedPanelIds else { return }
        publishedRenderedPanelIds = renderedPanelIds
        callbacks.onViewportGeometryChanged(window)
    }

    func isRendering(_ controller: CanvasPageViewController, requiresWindow: Bool = true) -> Bool {
        shouldRenderPreparedPages && controller.isRendered(in: pageController.view, requiresWindow: requiresWindow)
    }

    /// Returns page objects ordered by their canvas position.
    func orderedPageObjects(from layout: CanvasLayout) -> [CanvasPageObject] {
        layout.panes.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.frame
                let right = rhs.element.frame
                if left.midX != right.midX {
                    return left.midX < right.midX
                }
                if left.midY != right.midY {
                    return left.midY < right.midY
                }
                return lhs.offset < rhs.offset
            }
            .map { CanvasPageObject(pane: $0.element) }
    }
}
