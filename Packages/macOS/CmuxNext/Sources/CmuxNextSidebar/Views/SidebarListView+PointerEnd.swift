import AppKit
import CmuxNextInput
import CmuxNextWakeups

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
// release's own dispatch (`pointerEventSeen`, `releaseDispatched`).
extension SidebarListViewComponents {
    /// Ends whatever pointer gesture the list still holds: a live drag is cancelled (its rows spring back to where
    /// they were, the model untouched: a drag sends nothing before its drop), a pending press clicks nothing on its
    /// release, and every realized row's fills match the model again.
    func endPointerGesture() {
        if drag != nil { cancelDrag() }
        press = nil
        syncRowStates()
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

    /// Whether a gesture is alive: a press or a drag the list still holds.
    var holdsPointerGesture: Bool { press != nil || drag != nil }

    /// A left press or release anywhere in the app, before its window gets it (`observePointerEnds`).
    /// - A press while this list still holds one: the old press's release never came (a menu, a modal session or
    ///   another tracking loop took it). It ends now, wherever the new press lands; a press on the list ends it too.
    /// - A release sent to another window: a panel over this window may still forward it here (`WindowOverlayHost`),
    ///   so nothing ends during its dispatch (`releaseDispatched` looks again once it is over).
    /// Returns true when the gesture ended now.
    @discardableResult
    func pointerEventSeen(_ type: NSEvent.EventType, in eventWindow: NSWindow?) -> Bool {
        guard holdsPointerGesture, type == .leftMouseDown else { return false }
        endPointerGesture()
        return true
    }

    /// A left release's dispatch is over (`observePointerEnds`). One sent to another window that did not end the
    /// gesture there, with no new press begun, lost its release: the gesture ends.
    func releaseDispatched(in eventWindow: NSWindow?) {
        guard eventWindow !== window else { return }
        endReleasedGesture()
    }

    /// A release went elsewhere and its dispatch is over: a gesture still alive with the button up has lost its release.
    func endReleasedGesture() {
        guard holdsPointerGesture, !leftButtonIsDown() else { return }
        endPointerGesture()
    }

    /// Hears every left press and release of the app on `tap` while the list holds a gesture: presses before their
    /// window gets them (`pointerEventSeen`), releases once their dispatch is over (`releaseDispatched`). Every
    /// window: the release that ends a gesture is the one that went to another window. Both subscriptions end when
    /// the returned array is released; the caller keeps it while the list is in a window.
    func observePointerEnds(on tap: InputEventTap) -> [InputSubscription] {
        let holds: @MainActor () -> Bool = { [weak self] in self?.holdsPointerGesture ?? false }
        let presses = tap.subscribe(class: .button, while: holds) { [weak self] event in
            if event.type == .leftMouseDown { _ = self?.pointerEventSeen(event.type, in: event.window) }
        }
        let releases = tap.subscribe(class: .button, phase: .afterDispatch, while: holds) { [weak self] event in
            if event.type == .leftMouseUp { self?.releaseDispatched(in: event.window) }
        }
        return [presses, releases]
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
            case let (.group(id), header as GroupHeaderRowView):
                header.isDropTarget = drag?.target == .intoGroup(id) || external?.proposal == .intoGroup(id)
            default:
                break
            }
        }
    }

    /// Observes the window losing key (`pointerWindowLostKey`) and the app resigning active (`pointerFocusLost`): one
    /// observer per window and per app, fanned out (``WindowEvents``, ``AppEvents``). No node: a gesture the list
    /// holds ends whether or not the list shows, as a Chromium view ends its press when it loses the mouse capture
    /// (ui/views/view.h, `View::OnMouseCaptureLost`).
    func observeFocusLoss(of window: NSWindow?) -> [EventSubscription] {
        var observers = [appEvents.subscribe(NSApplication.didResignActiveNotification, owner: "SidebarListView.pointerEnd") { [weak self] in
            self?.pointerFocusLost()
        }]
        if let window {
            observers.append(WindowEvents.of(window).subscribe(NSWindow.didResignKeyNotification, owner: "SidebarListView.pointerEnd") { [weak self] in
                self?.pointerWindowLostKey()
            })
        }
        return observers
    }
}
