import AppKit

/// cmux: MessagesLab's thread and reply view controls (Host.swift: `escape`,
/// `installOutsideClick`, `installEscape`, `clicked`'s "N Replies", not
/// vendored), for the pane controller. The view itself (rows, ThreadBackdrop,
/// fly in and out) is the vendored WindowView's, driven by `openThread`; the
/// reply leaves through `ChatIntents.send` with the thread root.
/// Offered only when the owner can take a reply (`ChatIntents.canReply`).
final class PaneThread {
    /// The owning controller (it holds this object; weak, so no cycle).
    private weak var controller: ChatController?
    private var monitors: [Any] = []
    /// The press the outside-click monitor took (a mouse down and its up share the number).
    private var swallowedPress: Int?
    /// The transcript row whose "N Replies" or thread preview opened the view (its row key), while the
    /// view is open. A click on that row again is a click on the thread, not on the backdrop: the
    /// view moves its rows, so the opener's spot is blurred backdrop, and closing there flipped the
    /// view shut on the person's second click (Lawrence's scrawl capture, 2026-10-29).
    private var openerKey: String?

    init(controller: ChatController) { self.controller = controller }

    deinit { monitors.forEach { NSEvent.removeMonitor($0) } }

    private var openThread: PartRef? { controller?.store?.state.ui.openThread }
    private var field: NSTextView? { controller?.demo?.compose.textView.view }

    /// Host.swift's dispatch: opening or closing a view.
    func note(_ a: Action) {
        switch a {
        case .reply, .closeThread, .openThreadPath:
            openerKey = nil
            // The user moved: a permalink still waiting for its message no longer opens it later.
            controller?.intents?.threadMovedByUser()
        default: break
        }
    }

    /// Esc while a view is open: one Esc closes it and the caret goes to the composer, so
    /// the person is back in the main chat ready to type. cmux: Messages' first Esc only
    /// unfocused the field, which read as Esc doing nothing (Lawrence 2026-10-21: "pressing
    /// esc when in reply view ... needs to escape it"). False when no view is open (the key
    /// goes on to other handlers).
    func escape() -> Bool {
        guard let controller, openThread != nil else { return false }
        controller.dispatch(.closeThread)
        controller.focusCompose()
        return true
    }

    /// A click (`ChatController.clicked`): outside an open view's content closes it;
    /// "N Replies" or a thread preview opens its thread with the field not focused
    /// (Messages: the first Esc then closes it). True when the click was taken.
    func clicked(_ p: CGPoint) -> Bool {
        guard let controller, let demo = controller.demo else { return false }
        // A tree thread view's own controls first (ThreadHost.swift): "N Replies" under a reply opens its
        // branch, the breadcrumb pops or opens a level. nil in `.messages` mode and outside them.
        if openThread != nil, demo.threadContentContains(p), let control = demo.hostControl(at: p) {
            if case let .dispatch(action) = control { controller.dispatch(action) }
            return true
        }
        guard controller.intents?.canReply == true else { return false }
        if openThread != nil {
            guard !demo.threadContentContains(p), !demo.compose.fieldRect.insetBy(dx: -60, dy: -8).contains(p) else { return false }
            // The opener again: Messages keeps the thread open (and still).
            if let key = openerKey, demo.rowFrame(key: key)?.contains(p) == true { return true }
            controller.dispatch(.closeThread)
            return true
        }
        guard let root = demo.repliesHit(p) else { return false }
        let opener = demo.rowKey(at: p)
        focusTranscript()
        controller.dispatch(.reply(root))
        if controller.store?.state.ui.openThread != nil { openerKey = opener }
        return true
    }

    /// Host.swift's monitors: a click in the pane outside an open view's content closes
    /// it before a bubble behind the blur takes the press, and Esc closes it wherever the
    /// key focus is (the field handles its own Esc through `escape`).
    func install() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] e in
            guard let self, let controller = self.controller, self.isLive(e), controller.picker == nil else { return e }
            let host = controller.host
            let p = host.convert(e.locationInWindow, from: nil)
            guard host.bounds.contains(p), self.clicked(p) else { return e }
            self.swallowedPress = e.eventNumber
            return nil
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            // Only while the key focus is in this pane (a terminal, the sidebar or the palette keep their Esc).
            guard e.keyCode == 53, let self, let controller = self.controller, self.isLive(e), controller.picker == nil,
                  let focus = controller.window?.firstResponder as? NSView, focus.isDescendant(of: controller.host),
                  focus !== self.field else { return e }
            return self.escape() ? nil : e
        }) { monitors.append(m) }
    }

    /// The mouse up of a press the outside-click monitor took: the click is done.
    func swallowed(_ e: NSEvent) -> Bool {
        guard let n = swallowedPress else { return false }
        swallowedPress = nil
        return n == e.eventNumber
    }

    /// The event is in this pane's window, the pane shows, and a thread or reply view is open.
    private func isLive(_ e: NSEvent) -> Bool {
        guard let host = controller?.host else { return false }
        return openThread != nil && e.window != nil && e.window === host.window && !host.isHiddenOrHasHiddenAncestor
    }

    /// Real Messages: opening a thread from "N Replies" leaves no caret in the field.
    private func focusTranscript() {
        guard let controller else { return }
        let doc = controller.host.scrollView.document
        doc.takesFocus = true
        controller.window?.makeFirstResponder(doc)
        doc.takesFocus = false
    }
}
