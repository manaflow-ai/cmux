import AppKit
import CmuxNextActions
import CmuxNextHistory

/// The titlebar band's Back and Forward (R69): a click runs
/// focusHistoryBack / focusHistoryForward, the right-click or long-press list
/// runs `history.goTo {index}` (laid out by Debug Settings `history.menuLayout`), and each button is enabled only while the
/// shown page's history or the trail has somewhere to go (history.md 4.2b).
extension WindowController {
    func installHistoryButtons() {
        let band = root.toolbarBand
        let registry = services.registry
        band.onHistory = { [weak registry] direction in
            _ = registry?.perform(direction == .back ? "focusHistoryBack" : "focusHistoryForward", invocation: ActionInvocation(origin: .user))
        }
        band.historyMenu = { [weak services, weak registry] direction in
            guard let services, services.locationTrail.scope != .surface else { return nil }
            let layout = TitlebarHistoryTunables.menuLayout.value
            let sections = services.locationTrail.menuSections(direction, layout: layout)
            // The `scope` layout is the R69 list as it was: nothing to list, no menu. The others
            // always open, so a right-click is never dead (Show All History at least).
            if layout == .scope, sections.isEmpty { return nil }
            // Show All History is the registered `history.show` row, not a menu-only handler.
            let showAll = layout == .scope ? nil : registry?.makeMenuItem(for: "history.show")
            return TitlebarHistoryMenu.make(sections, choose: { index in
                _ = registry?.perform("history.goTo", invocation: ActionInvocation(arguments: ["index": .int(index)], origin: .user))
            }, showAll: showAll)
        }
        // The sidebar toggle's right-click (cx-2lm4): the menu of the sidebar's empty space.
        band.sidebarToggle.longPressOpensMenu = false
        band.sidebarToggle.menuProvider = { [weak sidebar] in sidebar?.contextMenu(for: .background) }
        band.describeHistory(back: registry.descriptor(for: "focusHistoryBack")?.title ?? "",
                             forward: registry.descriptor(for: "focusHistoryForward")?.title ?? "",
                             backShortcut: registry.shortcutDisplay(for: "focusHistoryBack"),
                             forwardShortcut: registry.shortcutDisplay(for: "focusHistoryForward"))
        // Each window listens for itself; windowWillClose removes it.
        band.historyObserver = services.locationTrail.addObserver { [weak self] in self?.refreshHistoryButtons() }
        refreshHistoryButtons()
    }

    /// Stops listening to the trail (the window closes).
    func removeHistoryObserver() {
        guard let token = root.toolbarBand.historyObserver else { return }
        services.locationTrail.removeObserver(token)
        root.toolbarBand.historyObserver = nil
    }

    /// Re-reads whether Back and Forward have somewhere to go.
    func refreshHistoryButtons() {
        let trail = services.locationTrail
        root.toolbarBand.setHistoryEnabled(back: trail.canNavigate(.back, in: self), forward: trail.canNavigate(.forward, in: self))
    }
}
