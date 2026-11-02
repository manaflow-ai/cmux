import AppKit
import CmuxNextDesign

// Leo 2026-10-20 (nightly): a click during a drag, a click that became a small drag, or a quick double-click left a
// row in the selection fill that never cleared, beside the focused one. The fills a gesture sets (the hovered row, the
// drop target, a multi-selection's second rows) must end with it: on release, on a cancel (Escape), and when the
// window or the app loses focus with the button still down (its release then goes to another window, never here, and
// the drag stayed alive with its rows hidden).
//
// Leo 2026-10-21: "AND THEN THE HELD DRAGGED, IT GETS STUCK". A press on a row switches to its workspace, and when
// that workspace shows a Chromium page or agent page, the page's child window takes the keys a moment later. This
// window then resigned key with the button still held, and the gesture ended under the hand: the press was dropped,
// so the row never lifted, or a lifted row flew back and stopped following the pointer. AppKit sends the rest of a
// click (its drags and its release) to the window that got the press, key or not, so a key change while the button
// is held ends nothing. A release that really went elsewhere ends the gesture at the app's next press, or after the
// release's own dispatch (`pointerEventSeen`).
//
// Lawrence 2026-10-30 ("i tried to drag home around and now it's stuck in this state"): the list owns every press and
// drag in its rows and in its blocks' items (Home, the pinned rows), and this is the one end of all of them. A block
// item's press kept its pressed fill when its gesture ended anywhere but on its own release, because only the item
// itself could clear it; every exit path now runs `endPointerGesture`, which ends the items' presses too.
extension SidebarListViewComponents {
    /// The one end of every pointer gesture the list holds, success or not: a live drag is cancelled (its rows spring
    /// back to where they were, the model untouched: a drag sends nothing before its drop), a pending press clicks
    /// nothing on its release, every block item's press ends (its pressed fill clears, a tile the drag hid shows when
    /// its card is home), every realized row's fills match the model again, and the hover is the pointer's now.
    func endPointerGesture() {
        if drag != nil { cancelDrag() }
        press = nil
        let flyingTile = landing?.tileSource?.item // its landing shows it when the card arrives
        for region in blockRegions { region.endItemPresses(except: region === landing?.tileRegion ? flyingTile : nil) }
        syncRowStates()
        PointerHover.refresh(in: window)
    }

    /// The app lost focus: the gesture ends and no row stays hovered (the pointer's next move hovers again).
    func pointerFocusLost() {
        endPointerGesture()
        setHovered(nil)
    }

    /// The window stopped being key. With the left button still held, the press goes on: its drags and its release
    /// still come to this window (a child page window took the keys after the press switched workspaces). With the
    /// button up, the release went to another window: the gesture ends as for the app losing focus.
    func pointerWindowLostKey() {
        if holdsPointerGesture, leftButtonIsDown() { return }
        pointerFocusLost()
    }

    /// Whether a gesture is alive: a press or a drag the list still holds, or a press on one of its blocks' items.
    var holdsPointerGesture: Bool { press != nil || drag != nil || blockRegions.contains(where: \.holdsItemPress) }

    /// A left press or release anywhere in the app, before its window gets it (`observePointerEnds`).
    /// - A press while this list still holds one: the old press's release never came (a menu, a modal session or
    ///   another tracking loop took it). It ends now, wherever the new press lands; a press on the list ends it too.
    /// - A release anywhere: the gesture ends after that release's dispatch if it is still alive then. One sent to
    ///   another window may still be forwarded here by a panel over this window (`WindowOverlayHost`); one sent to
    ///   this window may reach a view that does not hold the gesture (the pressed item left under the pointer, the
    ///   list reloaded under the drag). Either way a gesture its release did not end ends then, as a cancel.
    /// Returns true when the gesture ended now. `screenPoint`: where the event happened, on screen.
    @discardableResult
    func pointerEventSeen(_ type: NSEvent.EventType, in eventWindow: NSWindow?, at screenPoint: NSPoint? = nil) -> Bool {
        guard holdsPointerGesture else { return false }
        switch type {
        case .leftMouseDown:
            endPointerGesture()
            return true
        case .leftMouseUp:
            // task-owner: one hop after the release's dispatch; ends at once (nothing to end when the release did)
            Task { @MainActor [weak self] in self?.endReleasedGesture(at: screenPoint) }
            return false
        default:
            return false
        }
    }

    /// A release went elsewhere (`screenPoint`: where) and its dispatch is over: a gesture still alive with the button
    /// up has lost its release. A drag released beside the sidebar (over another window or the desktop) is still a drag
    /// out: its item comes off (`finishDragOut`).
    func endReleasedGesture(at screenPoint: NSPoint? = nil) {
        guard holdsPointerGesture, !leftButtonIsDown() else { return }
        if let drag, let screenPoint, let window, finishDragOut(drag, at: window.convertPoint(fromScreen: screenPoint)) {
            press = nil
            return syncRowStates()
        }
        endPointerGesture()
    }

    /// Sees every left press and release of the app before its window does (`pointerEventSeen`), and Escape while
    /// a gesture is held (`escapeSeen`: it cancels the gesture, wherever the keys go); the caller removes it.
    func observePointerEnds() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            if event.type == .keyDown { return event.keyCode == 53 && self?.escapeSeen() == true ? nil : event }
            // A window's event is in its coordinates; one with no window (the desktop's) is on screen.
            _ = self?.pointerEventSeen(event.type, in: event.window,
                                       at: event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow)
            return event
        }
    }

    /// Whether `row` is a group's one row (`SidebarLayout+SoleMember`) and a drop goes into its group: the row draws
    /// the group's drop fill, as its header did, since that group has no header and the drop opens no gap.
    func standsForDropGroup(_ row: SidebarRow) -> Bool {
        guard row.standsForGroup, let group = row.group else { return false }
        return drag?.target == .intoGroup(group) || external?.proposal == .intoGroup(group)
    }

    /// The header a drop into `group` lines up with (its depth sets the gap's and the card's step-in): the group's
    /// header row, or for a group drawn as its one row, the header that row stands for (`SidebarRow.standingHeader`).
    func dropHeader(_ group: GroupID, in layout: SidebarLayout) -> SidebarRow? {
        guard let row = layout.groupRow(group) else { return nil }
        return row.standingHeader ?? row
    }

    /// Escape while a press or drag is held: the gesture ends as a cancel (true: the key is used).
    func escapeSeen() -> Bool {
        guard holdsPointerGesture else { return false }
        endPointerGesture()
        return true
    }

    /// An open empty group's insertion position is its header's drop target, too. Keep this
    /// visual state tied to the live drag; at rest the header has no empty-state decoration.
    func highlightsDropGroup(_ id: GroupID) -> Bool {
        if drag?.target == .intoGroup(id) || external?.proposal == .intoGroup(id) { return true }
        guard case let .position(position)? = drag?.target, position.group == id,
              groups[id]?.members.isEmpty == true else { return false }
        return true
    }

    /// Sets each realized row's selection, multi-selection and drop-target fill from the model and the live drag, as
    /// `configure` would, without configuring the rows (no content, no layout: a click stays cheap, u2455). A row whose
    /// fill a gesture left behind clears here.
    func syncRowStates() {
        for (key, view) in rowViews {
            view.isSelected = selectedRowKey == key
            switch (key, view) {
            case let (.workspace(id), row as WorkspaceRowView):
                paintSecondaryFills(row, id)
                row.isDropTarget = external?.proposal == .intoWorkspace(id) || drag?.target == .ontoWorkspace(id)
                    || displayed.row(for: key).map(standsForDropGroup) == true
            case let (.group(id), header as GroupHeaderRowView):
                header.isDropTarget = highlightsDropGroup(id)
            default:
                break
            }
        }
    }

    /// Observes the window losing key (`pointerWindowLostKey`) and the app resigning active (`pointerFocusLost`).
    func observeFocusLoss(of window: NSWindow?) -> [any NSObjectProtocol] {
        let center = NotificationCenter.default
        // queue: .main (inline for AppKit's post on main); a selector into this main-actor view trapped off main.
        var observers = [center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerFocusLost() } // main-proof: observer on queue: .main
        }]
        if let window {
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerWindowLostKey() } // main-proof: observer on queue: .main
            })
        }
        return observers
    }
}
