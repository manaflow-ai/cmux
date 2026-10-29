import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSidebar
import CmuxNextTabs
import Observation

/// Composes hint snapshots from this window and its actual binding table.
@MainActor
final class WindowShortcutHints {
    private weak var controller: WindowController?
    private let overlay = ShortcutHintOverlayView()
    private var monitor: WindowScopedShortcutHintModifierMonitor?
    private var settingsTask: Task<Void, Never>?
    private var held: NSEvent.ModifierFlags?
    private var scrollMonitor: Any?
    private var scrollRefresh: Task<Void, Never>?

    init(controller: WindowController) {
        self.controller = controller
        guard let window = controller.window else { return }
        controller.root.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.setAccessibilityElement(false)
        monitor = WindowScopedShortcutHintModifierMonitor(window: window, keepsHints: { [weak self] in self?.keepsHints(for: $0) ?? false }) { [weak self] flags in
            self?.held = flags
            self?.refresh()
        }
        // Chips are a snapshot of where rows, tabs and panes are. A scroll moves them without a window
        // layout, so a scroll in this window while chips show re-places them.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak window] event in
            if let self, held != nil, event.window === window || event.window == nil { scrollDidChange() }
            return event
        }
        settingsTask = Task { [weak self] in
            for await enabled in ObservationStream({ DesignSettings.shared.showModifierHoldHints }) {
                self?.monitor?.setEnabled(enabled)
            }
        }
    }

    func refresh() {
        guard let controller else { return }
        overlay.frame = controller.root.bounds
        overlay.hints = held.map(hints(held:)) ?? []
    }

    /// Content scrolled while chips show: re-place them once the scrolled view has taken the event
    /// (the monitor runs before it), one refresh for any burst of events in the same turn.
    func scrollDidChange() {
        guard held != nil, scrollRefresh == nil else { return }
        scrollRefresh = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            scrollRefresh = nil
            if held != nil { refresh() }
        }
    }

    /// The chips a hold of `held` shows in this window now, from its resolved binding table.
    func hints(held: NSEvent.ModifierFlags) -> [ShortcutHintOverlayView.Hint] {
        guard let controller else { return [] }
        let root = controller.root
        let registry = controller.services.registry
        let context = controller.services.keyRouter.keyContext(for: controller.focus.state, facts: KeyRouter.Facts())
        let bindings = RegistryKeyBindings(registry)
        let table = bindings.table
        func label(_ action: ActionID, digit: Int? = nil) -> String? {
            guard KeyRouter.allows(registry.keyTier(for: action), id: action, focus: controller.focus.state) else { return nil }
            // Use the resolved table, including keybindings.json removals and rebindings.
            for entry in table.entries.reversed() where entry.command == action && entry.keys.count == 1 {
                guard let shortcut = entry.keys.first, shortcut.modifiers.contains(held), KeyRouter.isChord(shortcut.modifiers),
                      digit.map({ entry.argument == String($0) }) ?? (entry.argument == nil),
                      table.resolve(entry.keys, in: context, isRunnable: { bindings.canPerform($0, in: context.bits) }).winner == entry else { continue }
                return shortcut.displayString
            }
            return nil
        }
        var hints: [ShortcutHintOverlayView.Hint] = []
        let sidebar = controller.sidebar.container.sidebarView
        // One source of truth: the digit Cmd-digit selects (SidebarItemOrder.pick's inverse), for every
        // sidebar destination drawn (Home, the App Store, collapsed groups, workspace rows).
        let order = controller.sidebar.model.itemOrder, navigation = SidebarNavigation.settings(controller.services)
        // The thin rail (`sidebar.style` = rail) draws each chip beside its tick.
        let container = controller.sidebar.container, rail = container.railView
        let frames: [SidebarItem: CGRect] = container.isRailShown
            ? rail.shortcutHintItemFrames.mapValues { sidebar.convert($0, from: rail) } : sidebar.shortcutHintItemFrames
        for (item, rect) in frames.sorted(by: { $0.value.minY < $1.value.minY }) {
            guard let digit = order.number(for: item, navigation), let text = label("selectWorkspaceByNumber", digit: digit) else { continue }
            hints.append(.init(text: text, rect: root.convert(rect, from: sidebar), target: Self.target(item)))
        }
        for (index, rect) in sidebar.shortcutHintSpaceFrames.enumerated() where index < 9 {
            if let text = label("space.selectByNumber", digit: index + 1) {
                hints.append(.init(text: text, rect: root.convert(rect, from: sidebar)))
            }
        }
        if let pane = controller.content?.panes.values.first(where: { $0.paneKey == controller.focus.state.pane }) {
            let strip = pane.view.stripView
            // Select Tab 1…9 counts the tabs the strip shows: a collapsed group's members take no number.
            let visible = Set(pane.stripModel.visibleOrderedTabs.map(\.id))
            let order = strip.presentedTabIDs.filter(visible.contains)
            for (id, rect) in TabShortcutHintGeometry().frames(in: strip) {
                guard let index = order.firstIndex(of: id) else { continue }
                guard index < 8 || index == order.count - 1 else { continue }
                let digit = index == order.count - 1 && index >= 8 ? 9 : index + 1
                guard digit <= 9, let text = label("selectSurfaceByNumber", digit: digit) else { continue }
                hints.append(.init(text: text, rect: root.convert(rect, from: strip)))
            }
        }
        // Pane navigation: each pane of the focused screen shows its Focus Pane 1…9 key and the key of
        // every pane-navigation action that moves focus to it from the focused pane (one chip per pane).
        if let content = controller.content,
           let focused = content.panes.values.first(where: { $0.paneKey == controller.focus.state.pane }),
           let screen = content.layoutModel.screen(containing: focused.layoutPaneID) {
            let plan = PaneNavigationHintPlan(order: screen.layout.visualPanes, focused: focused.layoutPaneID) { move in
                let direction: LayoutDirection? = switch move {
                case .left: .left
                case .right: .right
                case .up: .up
                case .down: .down
                case .previous, .next: nil
                }
                return direction.flatMap { PaneHandlers.neighbor(of: focused.layoutPaneID, direction: $0, in: content) }
            }
            for chip in plan.chips(label: { label($0, digit: $1) }) {
                guard let pane = content.panes[chip.pane] else { continue }
                hints.append(.init(text: chip.text, rect: root.convert(pane.view.bounds, from: pane.view), target: "pane:\(pane.paneKey)"))
            }
        }
        for (action, rect) in [(ActionID(rawValue: "toggleSidebar"), root.sidebarToggleFrame),
                               ("focusHistoryBack", root.historyButtonFrame(.back)),
                               ("focusHistoryForward", root.historyButtonFrame(.forward))] {
            if let rect, let text = label(action) { hints.append(.init(text: text, rect: root.convert(rect, from: nil), row: .titlebar)) }
        }
        return hints
    }

    /// What a sidebar chip selects, for debug readback (`debug.shortcut_hints`).
    private static func target(_ item: SidebarItem) -> String {
        switch item {
        case .workspace(let id): "workspace:\(id.rawValue)"
        case .group(let id): "group:\(id.rawValue)"
        case .topItem(let id): "item:\(id.rawValue)"
        }
    }

    /// A key-down in this window: a pane-navigation key (by the resolved binding table, so a
    /// rebound one counts and a removed one does not) keeps the chips up while the modifier is
    /// held, and they follow focus once it settles; any other key hides them until release.
    func keyDown(_ event: NSEvent) { monitor?.keyDown(keepsHints: keepsHints(for: event)) }

    /// Whether `event` runs a pane-navigation action here.
    func keepsHints(for event: NSEvent) -> Bool {
        // Typing (no Cmd, Ctrl or Option) never resolves the table: this runs on every key-down.
        guard event.type == .keyDown, KeyRouter.isChord(event.modifierFlags), let controller,
              let candidate = controller.services.keyRouter.candidate(for: event, focus: controller.focus.state) else { return false }
        return PaneNavigationHintPlan<LayoutPaneID>.keepsHintsUp.contains(candidate.id)
    }

    /// Focus settled: chips shown for a held modifier move to the new focus.
    func focusDidSettle() {
        guard held != nil else { return }
        refresh()
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    var shownHints: [ShortcutHintOverlayView.Hint] { overlay.hints }
    /// Shows the chips of a hold without the 0.3 s intentional-hold wait or key-window checks.
    func debugShow(_ flags: NSEvent.ModifierFlags) {
        held = flags
        refresh()
    }
    func debugHold(_ flags: NSEvent.ModifierFlags) async -> Bool {
        guard let monitor, let window = controller?.window else { return false }
        return await monitor.debugHold(flags, window: window)
    }
    #endif

    func stop() {
        monitor?.stop()
        settingsTask?.cancel()
        scrollRefresh?.cancel()
        scrollRefresh = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        overlay.removeFromSuperview()
    }
}
