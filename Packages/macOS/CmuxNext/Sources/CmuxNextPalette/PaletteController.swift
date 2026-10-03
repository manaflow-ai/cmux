public import AppKit
public import CmuxNextActions
import CmuxNextDesign

/// Which page the palette opens on.
public enum PaletteMode: Sendable, Hashable {
    case commands
    case keyboardShortcuts
    case workspaces
    case tabs
}

/// Owns the floating palette panel and wires the model to the registry and
/// the App's data sources.
///
/// Usage from the App:
/// ```swift
/// let palette = PaletteController(registry: registry, sources: sources)
/// palette.bindRegistryActions()   // Cmd-Shift-P, Cmd-P, shortcut search
/// ```
public final class PaletteController {
    public let registry: ActionRegistry
    public let model: PaletteModel
    public var sources: PaletteSources

    public private(set) var isVisible = false
    /// Called synchronously when the panel opens (true) or closes (false),
    /// before any key-window change it causes, so the owner's focus overlay
    /// stack never lags the panel (plans/cmux-next/input-spec.md bug B7).
    public var onVisibilityChange: ((Bool) -> Void)?
    /// Main-thread phases of each open, request to committed first frame
    /// (the stall bench, `debug.timings`).
    public var onPresented: ((PaletteOpenTiming) -> Void)?
    private var openStarted: ContinuousClock.Instant?
    private var modelReady: ContinuousClock.Instant?

    /// What the user acted on when the palette opened (`PaletteSources.context`).
    public private(set) var capturedTargets: [ActionTargetRef] = []
    /// Cmd-K on an action: records a new shortcut for it. Set its `editor`
    /// (the App's cmux.json writer) to enable it.
    public private(set) lazy var shortcutRecorder = PaletteShortcutRecorder(registry: registry, model: model)
    private var panel: PalettePanel?
    private weak var parentWindow: NSWindow?
    private var presentationGeneration = 0

    public init(
        registry: ActionRegistry,
        sources: PaletteSources = PaletteSources(),
        frecencyPersistence: (any FrecencyPersisting)? = UserDefaultsFrecencyPersistence()
    ) {
        self.registry = registry
        self.sources = sources
        self.model = PaletteModel(persistence: frecencyPersistence)
        model.onDismiss = { [weak self] in self?.hide() }
        // A command that refuses shows why on its row instead of beeping,
        // and the palette comes back on the same page.
        model.performer = { [registry] handler in registry.reportingRefusal(handler) }
        model.onRefusal = { [weak self] _ in self?.presentAgain() }
        model.onEditShortcut = { [weak self] id in self?.shortcutRecorder.begin(id) ?? false }
        model.onDropShortcutRecorder = { [weak self] in self?.shortcutRecorder.abandon() }
        model.scopePage = { [weak self] scope, context in self?.page(forScope: scope, context: context) }
        model.onAnnounce = { [weak self] text in
            guard let element = self?.panel else { return }
            NSAccessibility.post(element: element, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    /// Reads the scope prototypes (Debug Settings) and the sources into the
    /// model's scope graph. Runs on every open, so a changed tunable
    /// applies on the next open.
    func configureScopes() {
        configureScopes(entry: PaletteScopeTunables.entryStyle.value, chip: PaletteScopeTunables.chipStyle.value,
                        itemActions: PaletteScopeTunables.itemActions.value)
    }

    func configureScopes(entry: PaletteScopeEntryStyle, chip: PaletteScopeChipStyle, itemActions: PaletteItemActionsStyle) {
        let config = PaletteNavConfig(prefixEntry: entry.prefixEntry, keywordEntry: entry.keywordEntry)
        var scopes = PaletteScopeCatalog.builtIns(
            tabs: sources.tabs != nil || sources.actionPages["tab.search"] != nil,
            workspaces: sources.workspaces != nil, settings: sources.settings != nil)
        scopes += sources.scopes.map(\.descriptor)
        model.navigation = PaletteNavReducer(graph: PaletteScopeGraph(root: PaletteScopeCatalog.root, scopes: scopes), config: config)
        model.itemActionsAsScope = itemActions == .scope
        model.chipStyle = chip
        model.scopeEntry = entry
    }

    /// Opens `scope` above the root (`palette.open`, a scope's shortcut).
    /// Returns false for a scope the graph does not have.
    @discardableResult
    public func show(scope: PaletteScopeID, query: String = "", relativeTo window: NSWindow? = nil) -> Bool {
        configureScopes()
        guard model.navigation.graph.contains(scope) else { return false }
        openStarted = .now
        captureContext()
        model.open(scope: scope, query: query)
        modelReady = .now
        present(relativeTo: window)
        return true
    }

    // MARK: Registry wiring

    /// Binds the palette's own catalog actions: Command Palette (toggle),
    /// Go to Workspace and Search Keyboard Shortcuts. Go to Tab is Search
    /// Tabs, which the App binds (`tab.search`).
    public func bindRegistryActions() {
        registry.bind("commandPalette") { [weak self] in self?.toggle(.commands) }
        registry.bind("palette.searchShortcuts") { [weak self] in self?.show(.keyboardShortcuts) }
        if sources.workspaces != nil {
            registry.bind("goToWorkspace") { [weak self] in self?.show(.workspaces) }
        }
        registry.argumentCollector = { [weak self] id, invocation in
            self?.collectArguments(for: id, invocation: invocation)
        }
    }

    /// Counts a run of `id` from any entrypoint toward palette ranking.
    public func recordUse(of id: ActionID) {
        model.recordUse("action:\(registry.canonicalID(for: id).rawValue)")
    }

    // MARK: Warm-up

    /// Loads the palette's localized string tables. Pure and thread-safe:
    /// call it off the main thread at launch so the first open does not
    /// read the tables from disk on the main thread.
    public nonisolated static func prewarmStrings() {
        _ = PaletteStrings.copyActionID
        for category in ActionCategory.allCases { _ = category.title }
    }

    /// Work of the first open, done ahead of it in steps (the App runs one
    /// step per idle moment after the first window shows), so the first
    /// open costs what later opens cost: step 0 creates the panel, its
    /// views and its window-server window; step 1 loads the command page
    /// and lays out its visible rows (row views, symbol images). Returns
    /// false when there is no further step.
    @discardableResult
    public func prepare(step: Int) -> Bool {
        guard !isVisible else { return false }
        switch step {
        case 0:
            guard panel == nil else { return true }
            let panel = makePanel()
            panel.contentView?.layoutSubtreeIfNeeded()
            return true
        case 1:
            guard let panel else { return false }
            configureScopes()
            model.reset(to: commandsPage())
            panel.contentView?.layoutSubtreeIfNeeded()
            return false
        default:
            return false
        }
    }

    // MARK: Presentation

    public func toggle(_ mode: PaletteMode = .commands, relativeTo window: NSWindow? = nil) {
        if isVisible {
            hide()
        } else {
            show(mode, relativeTo: window)
        }
    }

    /// Opens the palette over `window` (default: the key or main window).
    public func show(_ mode: PaletteMode = .commands, relativeTo window: NSWindow? = nil) {
        configureScopes()
        openStarted = .now
        captureContext()
        model.reset(to: page(for: mode))
        modelReady = .now
        present(relativeTo: window)
    }

    /// Opens the palette on `page` (a keyboard, menu or CLI run of an action
    /// the palette serves as a page).
    public func show(page: PalettePageSpec, relativeTo window: NSWindow? = nil) {
        configureScopes()
        openStarted = .now
        captureContext()
        model.reset(to: page)
        modelReady = .now
        present(relativeTo: window)
    }

    /// Opens the palette to collect the missing arguments of `id`, then runs
    /// it. Installed as the registry's `argumentCollector`, so a menu item or
    /// shortcut for an argument-taking action asks inline.
    public func collectArguments(for id: ActionID, invocation: ActionInvocation, relativeTo window: NSWindow? = nil) {
        guard let descriptor = registry.descriptor(for: id) else { return }
        captureContext()
        let flow = PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: sources.targets,
                                       captured: capturedTargets, preview: sources.argumentPreview)
        let effect = flow.effect(collected: invocation)
        if case .perform(let handler) = effect {
            // Nothing left to ask.
            handler()
            return
        }
        configureScopes()
        openStarted = .now
        model.reset(to: effect, fallback: commandsPage())
        modelReady = .now
        present(relativeTo: window)
    }

    /// Captures the focused objects on open. An open palette keeps what it
    /// captured (its focus overlay hides the content below it).
    func captureContext() {
        guard !isVisible else { return }
        capturedTargets = sources.context?() ?? []
    }

    private func present(relativeTo window: NSWindow?) {
        let started = openStarted ?? .now
        let modelDone = modelReady ?? started
        openStarted = nil
        modelReady = nil
        let createdPanel = panel == nil
        // The document window, never a Chromium page window over it (a child
        // window): hiding gives the keys back to the window, not the page.
        // `NSApplication.shared`: `NSApp` is nil in package-test processes.
        let app = NSApplication.shared
        var parent = window ?? app.keyWindow.flatMap { $0 is PalettePanel ? nil : $0 } ?? app.mainWindow
        while let owner = parent?.parent { parent = owner }
        let panel = self.panel ?? makePanel()
        let panelDone = ContinuousClock.now
        presentationGeneration += 1
        registry.context.insert(.paletteOpen)
        if isVisible {
            // Already open: switch pages in place.
            panel.makeKey()
            return
        }
        isVisible = true
        onVisibilityChange?(true)
        parentWindow = parent
        // The room (theme) of the window it opens over.
        (parent?.themeScope ?? .app).adopt(panel)
        panel.setFrame(frame(for: parent, size: PaletteLayout.windowSize), display: false)
        if let parent, panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        // Without the keys while the app is inactive (ActiveAppKeyPanel).
        panel.makeKeyAndOrderFront(nil)
        contentView?.focusField()
        contentView?.animateIn()
        if let onPresented {
            let presented = ContinuousClock.now
            CATransaction.setCompletionBlock {
                let committed = ContinuousClock.now
                onPresented(PaletteOpenTiming(
                    model: started.duration(to: modelDone), panel: modelDone.duration(to: panelDone),
                    present: panelDone.duration(to: presented), commit: presented.duration(to: committed),
                    createdPanel: createdPanel))
            }
        }
    }

    /// Shows the palette again over the window it was closed from, on the
    /// page it closed on (a refused command's notice).
    private func presentAgain() {
        guard !isVisible else { return }
        // Without a parent (opened while no window was key or main, as in a
        // no-activate run) `present` picks the key or main window again.
        present(relativeTo: parentWindow.flatMap { $0.isVisible ? $0 : nil })
    }

    /// Closes the palette. The parent window becomes key immediately so a
    /// command that runs right after sees the right focus; the panel fades
    /// out, then orders out.
    public func hide() {
        hide(restoringKey: true)
    }

    /// The panel while the palette is open (`debug.key` target `palette`).
    public var visiblePanel: NSWindow? { isVisible ? panel : nil }

    /// Key-downs in the panel that reached `noResponder(for:)` (the system
    /// beep) since launch.
    public var unhandledKeyDowns: Int { panel?.unhandledKeyDowns ?? 0 }

    /// Whether `window` is the palette's panel.
    public func owns(_ window: NSWindow) -> Bool { window === panel }

    /// `restoringKey` is false when the panel already lost key to a click
    /// elsewhere: that window keeps the keys (plans/cmux-next/input-spec.md,
    /// bug B5: re-keying the parent stole the click's window).
    private func hide(restoringKey: Bool) {
        guard isVisible, let panel else { return }
        isVisible = false
        registry.context.remove(.paletteOpen)
        onVisibilityChange?(false)
        model.closeActionsMenu()
        shortcutRecorder.abandon()
        model.shortcutRecorder = nil
        model.hover(nil)
        model.didHide()
        presentationGeneration += 1
        let generation = presentationGeneration
        // Only a panel that has the keys gives them back.
        if restoringKey, panel.isKeyWindow, let parentWindow, parentWindow.isVisible {
            parentWindow.makeKey()
        }
        contentView?.animateOut { [weak self, weak panel] in
            guard let self, let panel, self.presentationGeneration == generation else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.contentView?.resetAnimations()
        }
    }

    private var contentView: PaletteContentView? { panel?.contentView as? PaletteContentView }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(size: PaletteLayout.windowSize)
        let content = PaletteContentView(model: model)
        content.autoresizingMask = [.width, .height]
        content.onPreferredSizeChange = { [weak self, weak panel] size in
            guard let self, let panel, self.isVisible else { return }
            // Keep the top edge fixed when density changes while open.
            var frame = panel.frame
            frame.origin.y += frame.height - size.height
            frame.origin.x += (frame.width - size.width) / 2
            frame.size = size
            panel.setFrame(frame, display: true)
        }
        content.onRecorderOption = { [weak self] option in self?.shortcutRecorder.choose(option) }
        panel.contentView = content
        panel.keyHandler = { [weak self] event in self?.handleKeyDown(event) ?? false }
        panel.capturesKeyEquivalents = { [weak self] in self?.model.shortcutRecorder != nil }
        panel.capturesKeyEquivalent = { [weak self] event in
            guard let model = self?.model, PaletteKeyMap.isCloseItem(event) else { return false }
            return model.currentPageOwnsCloseKey || model.selectedItem?.closeCommand != nil
        }
        // Shown without the keys (app inactive): the keys going to another
        // window closes it like a click outside.
        panel.onKeyElsewhere = { [weak self] in self?.hide(restoringKey: false) }
        panel.onResignKey = { [weak self] in
            // Clicking elsewhere closes the palette; the
            // clicked window keeps the keys.
            self?.hide(restoringKey: false)
        }
        self.panel = panel
        return panel
    }

    /// Top-centered over the parent window at about a sixth of its height,
    /// clamped to the visible screen.
    private func frame(for parent: NSWindow?, size: CGSize) -> NSRect {
        let screen = parent?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let anchor = parent?.frame ?? visible
        var origin = NSPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.maxY - anchor.height / 6 - size.height + PaletteLayout.shadowMargin
        )
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    // MARK: Keys

    /// Maps a key-down in the panel to a palette command. Returns true when
    /// the event was consumed (so the text field never sees it).
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if model.shortcutRecorder != nil {
            return shortcutRecorder.handle(PaletteShortcutRecorder.shortcut(for: event), keyCode: event.keyCode, event: event)
        }
        guard let command = PaletteKeyMap.command(
            for: event,
            actionsMenuOpen: model.actionsMenu != nil,
            queryIsEmpty: model.query.isEmpty,
            registry: registry
        ) else { return false }
        return model.handle(command)
    }
}

/// Phases of one palette open on the main thread.
public struct PaletteOpenTiming: Sendable {
    /// Building the page's items and first results.
    public var model: Duration
    /// Creating the panel and its views (zero once it exists).
    public var panel: Duration
    /// Placing, ordering in and focusing the panel.
    public var present: Duration
    /// Layout, display and the Core Animation commit of the first frame.
    public var commit: Duration
    public var createdPanel: Bool

    public var total: Duration { model + panel + present + commit }
}
