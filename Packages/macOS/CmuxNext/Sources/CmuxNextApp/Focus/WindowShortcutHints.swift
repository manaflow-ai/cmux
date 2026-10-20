import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
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

    init(controller: WindowController) {
        self.controller = controller
        guard let window = controller.window else { return }
        controller.root.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.setAccessibilityElement(false)
        monitor = WindowScopedShortcutHintModifierMonitor(window: window) { [weak self] flags in
            self?.held = flags
            self?.refresh()
        }
        settingsTask = Task { [weak self] in
            for await enabled in ObservationStream({ DesignSettings.shared.showModifierHoldHints }) {
                self?.monitor?.setEnabled(enabled)
            }
        }
    }

    func refresh() {
        guard let controller else { return }
        let root = controller.root
        overlay.frame = root.bounds
        guard let held else { overlay.hints = []; return }
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
        // The digit Cmd-digit selects (SidebarNavigation.select's order), so Home and the App Store count too.
        let order = controller.sidebar.model.itemOrder, navigation = SidebarNavigation.settings(controller.services)
        for (id, rect) in sidebar.shortcutHintWorkspaceFrames.sorted(by: { $0.value.minY < $1.value.minY }) {
            guard let digit = order.number(for: .workspace(id), navigation), let text = label("selectWorkspaceByNumber", digit: digit) else { continue }
            hints.append(.init(text: text, rect: root.convert(rect, from: sidebar), target: "workspace:\(id.rawValue)"))
        }
        for (index, rect) in sidebar.shortcutHintSpaceFrames.enumerated() where index < 9 {
            if let text = label("space.selectByNumber", digit: index + 1) {
                hints.append(.init(text: text, rect: root.convert(rect, from: sidebar)))
            }
        }
        if let pane = controller.content?.panes.values.first(where: { $0.paneKey == controller.focus.state.pane }) {
            let strip = pane.view.stripView
            let order = strip.presentedTabIDs
            for (id, rect) in TabShortcutHintGeometry().frames(in: strip) {
                guard let index = order.firstIndex(of: id) else { continue }
                guard index < 8 || index == order.count - 1 else { continue }
                let digit = index == order.count - 1 && index >= 8 ? 9 : index + 1
                guard digit <= 9, let text = label("selectSurfaceByNumber", digit: digit) else { continue }
                hints.append(.init(text: text, rect: root.convert(rect, from: strip)))
            }
        }
        // Focus Pane 1…9: each pane of the focused screen, in Focus Next Pane order.
        if let content = controller.content,
           let focused = content.panes.values.first(where: { $0.paneKey == controller.focus.state.pane }),
           let screen = content.layoutModel.screen(containing: focused.layoutPaneID) {
            let order = screen.layout.panes
            for (index, id) in order.enumerated() {
                guard index < 8 || index == order.count - 1, let pane = content.panes[id] else { continue }
                let digit = index == order.count - 1 && index >= 8 ? 9 : index + 1
                guard digit <= 9, let text = label("focusPaneByNumber", digit: digit) else { continue }
                hints.append(.init(text: text, rect: root.convert(pane.view.bounds, from: pane.view)))
            }
        }
        for (action, rect) in [(ActionID(rawValue: "toggleSidebar"), root.sidebarToggleFrame),
                               ("focusHistoryBack", root.historyButtonFrame(.back)),
                               ("focusHistoryForward", root.historyButtonFrame(.forward))] {
            if let rect, let text = label(action) { hints.append(.init(text: text, rect: root.convert(rect, from: nil), row: .titlebar)) }
        }
        overlay.hints = hints
    }

    func keyDown() { monitor?.keyDown() }

    #if DEBUG
    var shownHints: [ShortcutHintOverlayView.Hint] { overlay.hints }
    func debugHold(_ flags: NSEvent.ModifierFlags) async -> Bool {
        guard let monitor, let window = controller?.window else { return false }
        return await monitor.debugHold(flags, window: window)
    }
    #endif

    func stop() {
        monitor?.stop()
        settingsTask?.cancel()
        overlay.removeFromSuperview()
    }
}
