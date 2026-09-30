public import AppKit
public import CmuxNextActions

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
    }

    // MARK: Registry wiring

    /// Binds the palette's own catalog actions: Command Palette (toggle),
    /// Go to Workspace, Go to Tab, and Search Keyboard Shortcuts.
    public func bindRegistryActions() {
        registry.bind("commandPalette") { [weak self] in self?.toggle(.commands) }
        registry.bind("palette.searchShortcuts") { [weak self] in self?.show(.keyboardShortcuts) }
        if sources.workspaces != nil {
            registry.bind("goToWorkspace") { [weak self] in self?.show(.workspaces) }
        }
        if sources.tabs != nil {
            registry.bind("palette.goToTab") { [weak self] in self?.show(.tabs) }
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
        openStarted = .now
        model.reset(to: page(for: mode))
        modelReady = .now
        present(relativeTo: window)
    }

    /// Opens the palette to collect the missing arguments of `id`, then runs
    /// it. Installed as the registry's `argumentCollector`, so a menu item or
    /// shortcut for an argument-taking action asks inline.
    public func collectArguments(for id: ActionID, invocation: ActionInvocation, relativeTo window: NSWindow? = nil) {
        guard let descriptor = registry.descriptor(for: id) else { return }
        let flow = PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: sources.targets)
        let effect = flow.effect(collected: invocation)
        if case .perform(let handler) = effect {
            // Nothing left to ask.
            handler()
            return
        }
        openStarted = .now
        model.reset(to: effect, fallback: commandsPage())
        modelReady = .now
        present(relativeTo: window)
    }

    private func present(relativeTo window: NSWindow?) {
        let started = openStarted ?? .now
        let modelDone = modelReady ?? started
        openStarted = nil
        modelReady = nil
        let createdPanel = panel == nil
        // The document window, never a Chromium page window over it (a child
        // window): hiding gives the keys back to the window, not the page.
        var parent = window ?? NSApp.keyWindow.flatMap { $0 is PalettePanel ? nil : $0 } ?? NSApp.mainWindow
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

    /// Closes the palette. The parent window becomes key immediately so a
    /// command that runs right after sees the right focus; the panel fades
    /// out, then orders out.
    public func hide() {
        hide(restoringKey: true)
    }

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
        model.hover(nil)
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
        panel.contentView = content
        panel.keyHandler = { [weak self] event in self?.handleKeyDown(event) ?? false }
        // Shown without the keys (app inactive): the keys going to another
        // window closes it like a click outside.
        panel.onKeyElsewhere = { [weak self] in self?.hide(restoringKey: false) }
        panel.onResignKey = { [weak self] in
            // Clicking elsewhere closes the palette, like Spotlight; the
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
