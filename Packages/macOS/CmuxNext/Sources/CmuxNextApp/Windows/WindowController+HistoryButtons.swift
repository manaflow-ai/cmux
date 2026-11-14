import AppKit
import CmuxNextActions
import CmuxNextHistory

/// The titlebar band's Back and Forward (R69): a click runs
/// focusHistoryBack / focusHistoryForward, the right-click or long-press list
/// runs `history.goTo {index}` (laid out by Debug Settings `history.menuLayout`), lists Recently
/// Closed (`history.reopen {id}`) and ends with Show Full History (`history.show`). Each button's
/// click is enabled only while the shown page's history or the trail has somewhere to go
/// (history.md 4.2b); its right-click list opens either way.
extension WindowController {
    func installHistoryButtons() {
        let band = root.toolbarBand
        let registry = services.registry
        band.onHistory = { [weak registry] direction in
            _ = registry?.perform(direction == .back ? "focusHistoryBack" : "focusHistoryForward", invocation: ActionInvocation(origin: .user))
        }
        band.historyMenu = { [weak services, weak registry] direction in
            guard let services else { return nil }
            let layout = TitlebarHistoryTunables.menuLayout.value, trail = services.locationTrail
            // With the `surface` scope the page's own list is Back's walk: no trail rows, Recently Closed still lists.
            let sections = trail.scope == .surface ? [] : trail.menuSections(direction, layout: layout)
            // Every layout always opens, a dimmed arrow's too. Recently Closed reads the mirrored closed history (bounded,
            // no daemon request) and keeps the list's size (`TitlebarHistoryMenuStyle`); Show Full History is the
            // registered `history.show` row.
            let closed = TitlebarHistoryClosedSection(services.history.closedEntries(limit: TitlebarHistoryMenu.closedLimit),
                                                      served: DaemonClosedHistory.isServed(in: services))
            return TitlebarHistoryMenu.make(sections, closed: closed, style: TitlebarHistoryTunables.menuStyle.value,
                                            choose: { Self.goTo(registry, $0) }, reopenRow: { id, title in
                // The row's own item by id, never the "newest closed" of an empty id.
                registry?.makeArgumentMenuItem(for: "history.reopen", arguments: ["id": .string(id)], title: title)
            }, showAll: registry?.makeMenuItem(for: "history.show"))
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

    private static func goTo(_ registry: ActionRegistry?, _ index: Int) {
        _ = registry?.perform("history.goTo", invocation: ActionInvocation(arguments: ["index": .int(index)], origin: .user))
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
