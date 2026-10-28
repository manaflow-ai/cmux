public import AppKit
public import CmuxNextActions
import CmuxNextCompatAppKit
import CmuxNextDesign
import CmuxNextSignposts
public import CmuxNextWakeups

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
    private let mainWork: MainWorkScheduler // the app's one main-thread scheduler: the panel renders at its frames
    public let model: PaletteModel
    public var sources: PaletteSources
    /// Additional rows the app hides from the registry page based on live Labs/debug state.
    public var hiddenActionIDs: (() -> Set<ActionID>)?
    /// The windows' frame-aligned pointer input (feature `pointerFrameHover`, the App's
    /// `hoverFrameInput`): the results and the Actions menu hover on a frame interval's first move and
    /// once more at its frame, at the latest point. Nil: each move hovers at once.
    public var hoverFrameInput: FrameInputCoalescers? {
        didSet { contentView?.hoverFrameInput = hoverFrameInput }
    }

    public private(set) var isVisible = false
    /// Called synchronously when the panel opens (true) or closes (false),
    /// before any key-window change it causes, so the owner's focus overlay
    /// stack never lags the panel (plans/cmux-next/input-spec.md bug B7).
    public var onVisibilityChange: ((Bool) -> Void)?
    /// Main-thread phases of each open, request to committed first frame
    /// (the stall bench, `debug.timings`).
    public var onPresented: ((PaletteOpenTiming) -> Void)?
    /// The `systemUptime` timestamp of the input event that opens the palette
    /// (a key-down), or nil when no event caused the open (CLI, socket). Read
    /// at the start of each open so ``PaletteOpenTiming/input`` covers the key
    /// router's time before the palette runs.
    public var openingEventTimestamp: (() -> TimeInterval?)?
    /// Where each open's `stall.palette_open` slice goes (tests pass one over their own trace runtime).
    var stallSignposter: Signposter = .stall
    private var openStarted: ContinuousClock.Instant?
    private var openInput: Duration = .zero
    private var modelReady: ContinuousClock.Instant?

    /// What the user acted on when the palette opened (`PaletteSources.context`).
    public private(set) var capturedTargets: [ActionTargetRef] = []
    /// Cmd-K on an action: records a new shortcut for it. Set its `editor`
    /// (the App's cmux.json writer) to enable it.
    public private(set) lazy var shortcutRecorder = PaletteShortcutRecorder(registry: registry, model: model)
    private var panel: PalettePanel?
    private weak var parentWindow: NSWindow?
    private var presentationGeneration = 0
    /// The open panel sits on a control (`show(scope:anchoredTo:)`), not centered over its window.
    private var isAnchored = false

    public init(
        registry: ActionRegistry,
        sources: PaletteSources = PaletteSources(),
        frecencyPersistence: (any FrecencyPersisting)? = UserDefaultsFrecencyPersistence(),
        usage: (any PaletteUsageStore)? = nil, mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget()),
        hoverFrameInput: FrameInputCoalescers? = nil
    ) {
        (self.registry, self.mainWork, self.sources, self.hoverFrameInput) = (registry, mainWork, sources, hoverFrameInput)
        self.model = PaletteModel(usage: usage ?? LocalPaletteUsageStore(persistence: frecencyPersistence))
        // What an open's first frame does not show (the command page's workspaces and tabs)
        // loads once that frame is committed.
        model.afterFrame = { work in scheduleAfterFrameCommit(work) }
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

    /// Opens `scope` above the root (`palette.open`, a scope's shortcut).
    /// Returns false for a scope the graph does not have.
    /// - Parameter anchor: a control the panel opens from (the sidebar's
    ///   Search button): the panel sits just above it, its leading edge on the
    ///   control's, inside the screen. Nil centers it over the window.
    @discardableResult
    public func show(scope: PaletteScopeID, query: String = "", relativeTo window: NSWindow? = nil, anchoredTo anchor: NSView? = nil) -> Bool {
        open(relativeTo: window ?? anchor?.window, anchor: anchor.flatMap(Self.screenRect(of:)),
             when: { model.navigation.graph.contains(scope) }) {
            captureContext()
            model.open(scope: scope, query: query)
        }
    }

    /// `view`'s frame on the screen, or nil when it is in no window.
    private static func screenRect(of view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
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

    /// The name of each ``prepare(step:)`` step, by step: the App posts one
    /// afterStartup task per name (its startup record and signpost).
    public nonisolated static let prepareStepNames: [StaticString] = ["Palette.prepare.0", "Palette.prepare.1"]

    /// Work of the first open, done ahead of it in steps (the App posts one
    /// step per ``prepareStepNames`` entry, each in its own idle frame after
    /// startup completes), so the first
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
            // sync-layout: the first open's layout, in an idle frame: the panel is not ordered in, so no window pass runs it.
            panel.contentView?.layoutSubtreeIfNeeded()
            return true
        case 1:
            guard let panel else { return false }
            configureScopes()
            model.reset(to: commandsPage())
            // sync-layout: the command page's visible rows lay out here in an idle frame, not on the first open.
            panel.contentView?.layoutSubtreeIfNeeded()
            return false
        default:
            return false
        }
    }

    // MARK: Presentation

    public func toggle(_ mode: PaletteMode = .commands, relativeTo window: NSWindow? = nil) {
        if isVisible { hide() } else { show(mode, relativeTo: window) }
    }

    /// Opens the palette over `window` (default: the key or main window).
    public func show(_ mode: PaletteMode = .commands, relativeTo window: NSWindow? = nil) {
        open(relativeTo: window) {
            captureContext()
            model.reset(to: page(for: mode))
        }
    }

    /// Opens the palette on `page` (a keyboard, menu or CLI run of an action
    /// the palette serves as a page).
    public func show(page: PalettePageSpec, relativeTo window: NSWindow? = nil) {
        open(relativeTo: window) {
            captureContext()
            model.reset(to: page)
        }
    }

    /// Opens the palette to collect the missing arguments of `id`, then runs
    /// it. Installed as the registry's `argumentCollector`, so a menu item or
    /// shortcut for an argument-taking action asks inline. `ask` also asks for
    /// one optional argument (``ActionRegistry/ask(_:_:_:)``: a menu Rename with
    /// no name asks for it here instead of in a separate dialog).
    public func collectArguments(for id: ActionID, invocation: ActionInvocation, asking ask: ActionArgumentAsk? = nil,
                                 relativeTo window: NSWindow? = nil) {
        guard let descriptor = registry.descriptor(for: id) else { return }
        // Without its arguments, an action that opens a scope opens it, as its palette row does.
        if ask == nil, invocation.arguments.isEmpty, let scope = scope(openedBy: id), show(scope: scope, relativeTo: window) { return }
        captureContext()
        let flow = PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: sources.targets,
                                       captured: capturedTargets, preview: sources.argumentPreview,
                                       swatches: sources.argumentSwatches, ask: ask)
        let effect = flow.effect(collected: invocation)
        if case .perform(let handler) = effect {
            // Nothing left to ask.
            handler()
            return
        }
        open(relativeTo: window) { model.reset(to: effect, fallback: commandsPage()) }
    }

    /// Captures the focused objects on open. An open palette keeps what it
    /// captured (its focus overlay hides the content below it).
    func captureContext() {
        guard !isVisible else { return }
        capturedTargets = sources.context?() ?? []
    }

    /// One open's main-thread work, inside one `stall.palette_open` thread slice (B/E, Chrome's scoped
    /// `TRACE_EVENT0`, base/trace_event/common/trace_event_common.h): the scopes configured, `accepts` (false
    /// opens nothing), the start mark, `buildModel` (the page's items and first results), then the panel shown.
    /// The first frame's commit (``PaletteOpenTiming/commit``) runs in a later turn, outside the slice.
    @discardableResult
    private func open(relativeTo window: NSWindow?, anchor: NSRect? = nil, when accepts: () -> Bool = { true },
                      buildModel: () -> Void) -> Bool {
        let slice = stallSignposter.begin(.stallPaletteOpen)
        defer { stallSignposter.end(.stallPaletteOpen, slice) }
        configureScopes()
        guard accepts() else { return false }
        markOpenStarted()
        buildModel()
        modelReady = .now
        present(relativeTo: window, anchor: anchor)
        return true
    }

    private func markOpenStarted() {
        openStarted = .now
        let now = ProcessInfo.processInfo.systemUptime
        if let stamp = openingEventTimestamp?(), stamp > 0, stamp <= now {
            openInput = .microseconds(Int64((now - stamp) * 1_000_000))
        } else {
            openInput = .zero
        }
    }

    /// `anchor`: the screen rect of the control the panel opens from, or nil.
    private func present(relativeTo window: NSWindow?, anchor: NSRect? = nil) {
        model.usage.prepare()
        let started = openStarted ?? .now
        let modelDone = modelReady ?? started
        let input = openInput
        openInput = .zero
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
        isAnchored = anchor != nil
        let size = PaletteLayout.windowSize
        panel.setFrame(anchor.map { frame(above: $0, on: parent?.screen, size: size) } ?? frame(for: parent, size: size), display: false)
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
            CATransaction.setMainCompletion {
                let committed = ContinuousClock.now
                onPresented(PaletteOpenTiming(
                    input: input, model: started.duration(to: modelDone), panel: modelDone.duration(to: panelDone),
                    present: panelDone.duration(to: presented), commit: presented.duration(to: committed),
                    createdPanel: createdPanel))
            }
        }
    }

    /// Shows the palette again over the window it was closed from, on the
    /// page it closed on (a refused command's notice).
    private func presentAgain() {
        guard !isVisible else { return }
        // An open too (`onPresented` reports it): its main-thread work is one `stall.palette_open` slice.
        let slice = stallSignposter.begin(.stallPaletteOpen)
        defer { stallSignposter.end(.stallPaletteOpen, slice) }
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

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The open palette's result list (`debug.scroll_frames`).
    public var debugResultsScrollView: NSScrollView? { isVisible ? contentView?.resultsScrollView : nil }
    #endif

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
        let content = PaletteContentView(model: model, mainWork: mainWork)
        content.hoverFrameInput = hoverFrameInput
        content.autoresizingMask = [.width, .height]
        content.onPreferredSizeChange = { [weak self, weak panel] size in
            guard let self, let panel, self.isVisible else { return }
            // Keep the top edge fixed when density changes while open; an
            // anchored panel keeps its bottom-left corner on its control.
            var frame = panel.frame
            if !self.isAnchored {
                frame.origin.y += frame.height - size.height
                frame.origin.x += (frame.width - size.width) / 2
            }
            frame.size = size
            panel.setFrame(frame, display: true)
        }
        content.onRecorderOption = { [weak self] option in self?.shortcutRecorder.choose(option) }
        panel.contentView = content
        panel.keyHandler = { [weak self, weak panel] event in self?.handleKeyDown(event, in: panel) ?? false }
        panel.onBecomeKey = { [weak self] in self?.contentView?.focusField() }
        panel.capturesKeyEquivalents = { [weak self] in self?.model.shortcutRecorder != nil }
        panel.capturesKeyEquivalent = { [weak self] event in
            guard let model = self?.model else { return false }
            if PaletteKeyMap.isActionsKey(event) { return model.selectedItem != nil || model.actionsMenu != nil }
            guard PaletteKeyMap.isCloseItem(event) else { return false }
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

    /// Just above `anchor` (a control's screen rect), the card's leading edge
    /// on the control's, clamped to the visible screen when there is one.
    private func frame(above anchor: NSRect, on screen: NSScreen?, size: CGSize) -> NSRect {
        let margin = PaletteLayout.shadowMargin
        var origin = NSPoint(x: anchor.minX - margin, y: anchor.maxY + Metrics.space2 - margin)
        if let visible = (screen ?? NSScreen.screens.first(where: { $0.frame.intersects(anchor) }))?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return NSRect(origin: origin, size: size)
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
    /// `window`: the panel the key went to (the event's own window when nil).
    func handleKeyDown(_ event: NSEvent, in window: NSWindow? = nil) -> Bool {
        let window = window ?? event.window
        if model.shortcutRecorder != nil {
            return shortcutRecorder.handle(PaletteShortcutRecorder.shortcut(for: event), keyCode: event.keyCode, event: event)
        }
        if Self.inputMethodOwns(event, in: window) { return false }
        let caret = Self.caret(in: window)
        guard let command = PaletteKeyMap.command(
            for: event,
            actionsMenuOpen: model.actionsMenu != nil,
            queryIsEmpty: model.query.isEmpty,
            registry: registry,
            hierarchical: model.currentPageIsHierarchical,
            caretAtEnd: caret.atEnd,
            caretAtStart: caret.atStart,
            selectedTogglesInPlace: model.selectedItem?.primary.togglesInPlace == true
        ) else { return false }
        return model.handle(command)
    }
}

/// Phases of one palette open on the main thread.
public struct PaletteOpenTiming: Sendable {
    /// The opening key-down's age when the palette began to open (the key
    /// router and action dispatch); zero without an input event.
    public var input: Duration = .zero
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
    /// Key-down to the committed first frame: ``input`` plus ``total``.
    public var keyToFrame: Duration { input + total }
}
