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
    /// The thread or reply view a reply was last sent from (nil after the view opens or closes).
    private var sentInView: PartRef?
    private var monitors: [Any] = []
    /// The press the outside-click monitor took (a mouse down and its up share the number).
    private var swallowedPress: Int?

    init(controller: ChatController) { self.controller = controller }

    deinit { monitors.forEach { NSEvent.removeMonitor($0) } }

    private var openThread: PartRef? { controller?.store?.state.ui.openThread }
    private var field: NSTextView? { controller?.demo?.compose.textView.view }

    /// Host.swift's dispatch: a send in an open view marks it; opening or closing clears it.
    func note(_ a: Action) {
        switch a {
        case .send: sentInView = openThread
        case .reply, .closeThread: sentInView = nil
        default: break
        }
    }

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
        return true
    }

    /// A click (`ChatController.clicked`): outside an open view's content closes it;
    /// "N Replies" or a thread preview opens its thread with the field not focused
    /// (Messages: the first Esc then closes it). True when the click was taken.
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
