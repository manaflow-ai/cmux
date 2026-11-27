import AppKit

/// cmux: MessagesLab's thread and reply view controls (Host.swift: `escape`,
/// `installOutsideClick`, `installEscape`, `clicked`'s "N Replies", not
/// vendored), for the pane controller. The view itself (rows, ThreadBackdrop,
/// fly in and out) is the vendored WindowView's, driven by `openThread`; the
/// reply leaves through `ChatIntents.send` with the thread root.
<<<<<<< HEAD
/// Opening a thread from "N Replies" is offered only when the owner can take a reply (`ChatIntents.canReply`);
/// closing one (an outside click, Esc) works in every chat, since a permalink opens threads in a read-only one too.
final class PaneThread {
    /// The owning controller (it holds this object; weak, so no cycle).
    private weak var controller: ChatController?
    private var monitors: [Any] = []
    /// The press the outside-click monitor took (a mouse down and its up share the number).
    private var swallowedPress: Int?
    /// Where the "N Replies" or thread preview that opened the view lies (its row's height, the part of its
    /// width that opens the thread), while the view is open. The next press of the same multi-click there
    /// (a double-click on the opener) is a click on the thread, not on the backdrop: the view moves its rows,
    /// so the opener's spot is blurred backdrop, and closing there flipped the view shut on the person's second
    /// press (Lawrence's scrawl capture, 2026-10-29). Any later click there is backdrop and closes the view, as
    /// the rest of the opener's row does (Lawrence 2026-11-07, 2026-11-23: "notice how clicking some parts fails
    /// to close it": the band had kept every click for as long as the view was open, over a date line or beside
    /// a bubble the view drew there).
    private var openerBand: CGRect?
=======
/// Offered only when the owner can take a reply (`ChatIntents.canReply`).
final class PaneThread {
    /// The owning controller (it holds this object; weak, so no cycle).
    private weak var controller: ChatController?
    /// The thread or reply view a reply was last sent from (nil after the view opens or closes).
    private var sentInView: PartRef?
    private var monitors: [Any] = []
    /// The press the outside-click monitor took (a mouse down and its up share the number).
    private var swallowedPress: Int?
>>>>>>> origin/main

    init(controller: ChatController) { self.controller = controller }

    deinit { monitors.forEach { NSEvent.removeMonitor($0) } }

    private var openThread: PartRef? { controller?.store?.state.ui.openThread }
    private var field: NSTextView? { controller?.demo?.compose.textView.view }

<<<<<<< HEAD
    /// Host.swift's dispatch: opening or closing a view.
    func note(_ a: Action) {
        switch a {
        case .reply, .closeThread, .openThreadPath:
            openerBand = nil
            // The user moved: a permalink still waiting for its message no longer opens it later.
            controller?.intents?.threadMovedByUser()
=======
    /// Host.swift's dispatch: a send in an open view marks it; opening or closing clears it.
    func note(_ a: Action) {
        switch a {
        case .send: sentInView = openThread
        case .reply, .closeThread: sentInView = nil
>>>>>>> origin/main
        default: break
        }
    }

<<<<<<< HEAD
    /// Esc while a view is open: one Esc closes it and the caret goes to the composer, so
    /// the person is back in the main chat ready to type. cmux: Messages' first Esc only
    /// unfocused the field, which read as Esc doing nothing (Lawrence 2026-10-21: "pressing
    /// esc when in reply view ... needs to escape it"). False when no view is open (the key
    /// goes on to other handlers).
    func escape() -> Bool {
        guard let controller, openThread != nil else { return false }
        controller.dispatch(.closeThread)
        controller.focusCompose()
=======
    /// Esc while a view is open. Messages: before a send in the view, the first Esc only
    /// unfocuses its field (the transcript takes the focus, so the next Esc still reaches
    /// this pane); after a reply was sent there, or with the field not focused, Esc closes
    /// the view. False when no view is open.
    func escape() -> Bool {
        guard let controller, let open = openThread else { return false }
        if let field, controller.window?.firstResponder === field, sentInView != open {
            focusTranscript()
        } else {
            controller.dispatch(.closeThread)
        }
>>>>>>> origin/main
        return true
    }

    /// A click (`ChatController.clicked`): outside an open view's content closes it;
    /// "N Replies" or a thread preview opens its thread with the field not focused
    /// (Messages: the first Esc then closes it). True when the click was taken.
<<<<<<< HEAD
    /// `clickCount`: the press's place in a multi-click (`NSEvent.clickCount`); a press after the first of the
    /// multi-click that opened the view, on the opener's spot, keeps it open (``openerBand``).
    func clicked(_ p: CGPoint, clickCount: Int = 1) -> Bool {
        guard let controller, let demo = controller.demo else { return false }
        // A tree thread view's own controls first (ThreadHost.swift): "N Replies" under a reply opens its
        // branch, the breadcrumb pops or opens a level. nil in `.messages` mode and outside them.
        if openThread != nil, demo.threadContentContains(p), let control = demo.hostControl(at: p) {
            if case let .dispatch(action) = control { controller.dispatch(action) }
            return true
        }
        // Closing is not replying: an outside click closes a thread in a chat that takes no replies too.
        if openThread != nil {
            guard !demo.threadContentHit(p), !demo.compose.fieldRect.insetBy(dx: -60, dy: -8).contains(p) else { return false }
            // The opener's double-click ("N Replies" or the preview, not the rest of its row): Messages keeps the
            // thread open (and still). A later single click there closes it.
            if clickCount > 1, let band = openerBand, band.contains(p) { return true }
            controller.dispatch(.closeThread)
            return true
        }
        guard controller.intents?.canReply == true else { return false }
        guard let root = demo.repliesHit(p) else { return false }
        let opener = Self.openerBand(at: p, in: demo)
        focusTranscript()
        controller.dispatch(.reply(root))
        if controller.store?.state.ui.openThread != nil { openerBand = opener }
=======
    func clicked(_ p: CGPoint) -> Bool {
        guard let controller, let demo = controller.demo, controller.intents?.canReply == true else { return false }
        if openThread != nil {
            guard !demo.threadContentContains(p), !demo.compose.fieldRect.insetBy(dx: -60, dy: -8).contains(p) else { return false }
            controller.dispatch(.closeThread)
            return true
        }
        guard let root = demo.repliesHit(p) else { return false }
        focusTranscript()
        controller.dispatch(.reply(root))
>>>>>>> origin/main
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
<<<<<<< HEAD
            guard host.bounds.contains(p), self.clicked(p, clickCount: e.clickCount) else { return e }
=======
            guard host.bounds.contains(p), self.clicked(p) else { return e }
>>>>>>> origin/main
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

<<<<<<< HEAD
    /// The part of the transcript row under `p` that opens a thread (``MessagesWindowView/repliesHit(_:)``), at
    /// the row's height; one scan of its width at `p`'s height, at the open only.
    private static func openerBand(at p: CGPoint, in demo: MessagesWindowView) -> CGRect? {
        guard let key = demo.rowKey(at: p), let row = demo.rowFrame(key: key) else { return nil }
        let xs = stride(from: row.minX, through: row.maxX, by: 2).filter { demo.repliesHit(CGPoint(x: $0, y: p.y)) != nil }
        guard let lo = xs.first, let hi = xs.last else { return nil }
        return CGRect(x: lo - 2, y: row.minY, width: hi - lo + 4, height: row.height)
    }

=======
>>>>>>> origin/main
    /// Real Messages: opening a thread from "N Replies" leaves no caret in the field.
    private func focusTranscript() {
        guard let controller else { return }
        let doc = controller.host.scrollView.document
        doc.takesFocus = true
        controller.window?.makeFirstResponder(doc)
        doc.takesFocus = false
    }
}
