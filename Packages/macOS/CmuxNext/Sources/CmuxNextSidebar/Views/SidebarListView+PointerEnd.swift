import AppKit

// Leo 2026-10-20 (nightly): a click during a drag, a click that became a small drag, or a quick double-click left a
// row in the selection fill that never cleared, beside the focused one. The fills a gesture sets (the hovered row, the
// drop target, a multi-selection's second rows) must end with it: on release, on a cancel (Escape), and when the
// window or the app loses focus with the button still down (its release then goes to another window, never here, and
// the drag stayed alive with its rows hidden).
extension SidebarListViewComponents {
    /// Ends whatever pointer gesture the list still holds: a live drag is cancelled (its rows spring back to where
    /// they were, the model untouched: a drag sends nothing before its drop), a pending press clicks nothing on its
    /// release, and every realized row's fills match the model again.
    func endPointerGesture() {
        if drag != nil { cancelDrag() }
        press = nil
        syncRowStates()
    }

    /// The window or the app lost focus: the gesture ends and no row stays hovered (the pointer's next move hovers again).
    func pointerFocusLost() {
        endPointerGesture()
        setHovered(nil)
    }

    /// Sets each realized row's selection, multi-selection and drop-target fill from the model and the live drag, as
    /// `configure` would, without configuring the rows (no content, no layout: a click stays cheap, u2455). A row whose
    /// fill a gesture left behind clears here.
    func syncRowStates() {
        for (key, view) in rowViews {
            view.isSelected = selectedRowKey == key
            switch (key, view) {
            case let (.workspace(id), row as WorkspaceRowView):
                row.isSecondarySelected = model.selection.contains(id) && !row.isSelected
                row.isDropTarget = external?.proposal == .intoWorkspace(id) || drag?.target == .ontoWorkspace(id)
            case let (.group(id), header as GroupHeaderRowView):
                header.isDropTarget = drag?.target == .intoGroup(id) || external?.proposal == .intoGroup(id)
            default:
                break
            }
        }
    }

    /// Observes the window losing key and the app resigning active (`pointerFocusLost`).
    func observeFocusLoss(of window: NSWindow?) -> [any NSObjectProtocol] {
        let center = NotificationCenter.default
        var names: [(Notification.Name, AnyObject?)] = [(NSApplication.didResignActiveNotification, NSApp)]
        if let window { names.append((NSWindow.didResignKeyNotification, window)) }
        // queue: .main (inline for AppKit's post on main); a selector into this main-actor view trapped off main.
        return names.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerFocusLost() } // main-proof: observer on queue: .main
            }
        }
    }
}
