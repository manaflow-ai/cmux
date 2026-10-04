import AppKit
import CmuxNextActions
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
            for await enabled in Observations({ DesignSettings.shared.showModifierHoldHints }) {
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
                guard let shortcut = entry.keys.first, shortcut.modifiers.contains(held),
                      digit.map({ entry.argument == String($0) }) ?? (entry.argument == nil),
                      table.resolve(entry.keys, in: context, isRunnable: { bindings.canPerform($0, in: context.bits) }).winner == entry else { continue }
                return shortcut.displayString
            }
            return nil
        }
        var hints: [ShortcutHintOverlayView.Hint] = []
        let sidebar = controller.sidebar.container.sidebarView
        let workspaces = controller.sidebar.model.selectableWorkspaces
        let frames = sidebar.shortcutHintWorkspaceFrames
        for (index, workspace) in workspaces.enumerated() {
            guard index < 8 || index == workspaces.count - 1 else { continue }
            let digit = index == workspaces.count - 1 && index >= 8 ? 9 : index + 1
            guard digit <= 9, let rect = frames[workspace.id], let text = label("selectWorkspaceByNumber", digit: digit) else { continue }
            hints.append(.init(text: text, rect: root.convert(rect, from: sidebar)))
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
        for (action, rect) in [(ActionID(rawValue: "toggleSidebar"), root.sidebarToggleFrame),
                               ("focusHistoryBack", root.historyButtonFrame(.back)),
                               ("focusHistoryForward", root.historyButtonFrame(.forward))] {
            if let rect, let text = label(action) { hints.append(.init(text: text, rect: root.convert(rect, from: nil))) }
        }
        overlay.hints = hints
    }

    func keyDown() { monitor?.keyDown() }

    func stop() {
        monitor?.stop()
        settingsTask?.cancel()
        overlay.removeFromSuperview()
    }
}
