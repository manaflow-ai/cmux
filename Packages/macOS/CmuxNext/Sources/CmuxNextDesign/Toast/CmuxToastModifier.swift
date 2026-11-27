import AppKit
public import SwiftUI

extension View {
    /// Shows `message` as a toast in this view's window while it is not nil,
    /// through the one toast component (`CmuxToastCenter`): SwiftUI panels
    /// (Feed, Tasks) get the same surface, place, stacking, timeout and
    /// hover hold as every other toast. `onDismiss` runs, on the next main
    /// actor turn, whenever the toast ends (its time ran out, its close
    /// button, a newer toast pushed it out of the stack) and when the view
    /// goes away, so the model clears the message and the same message
    /// shows again next time.
    public func cmuxToast(id: String, message: String?, duration: Duration = .seconds(6),
                          onDismiss: @escaping @MainActor () -> Void) -> some View {
        background(CmuxToastAnchor(id: id, message: message, duration: duration, onDismiss: onDismiss))
    }
}

private struct CmuxToastAnchor: NSViewRepresentable {
    let id: String
    let message: String?
    let duration: Duration
    let onDismiss: @MainActor () -> Void

    func makeNSView(context: Context) -> CmuxToastAnchorView { CmuxToastAnchorView() }

    func updateNSView(_ view: CmuxToastAnchorView, context: Context) {
        view.request = CmuxToastAnchorView.Request(id: id, message: message, duration: duration, onDismiss: onDismiss)
    }

    static func dismantleNSView(_ view: CmuxToastAnchorView, coordinator: ()) {
        view.dismantle()
    }
}

/// An invisible view that shows its requested message as a toast once it is
/// in a window, and ends that toast when the message goes.
@MainActor
final class CmuxToastAnchorView: NSView {
    struct Request {
        var id: String
        var message: String?
        var duration: Duration
        var onDismiss: @MainActor () -> Void
    }

    var request: Request? { didSet { present() } }
    /// The presenter (tests pass a headless one).
    var center: CmuxToastCenter = .shared
    private var shown: (message: String, handle: CmuxToastHandle)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        present()
    }

    private func present() {
        guard let request, let message = request.message, let window else {
            end()
            return
        }
        // Once per message: a toast that ended stays ended until the message changes.
        if shown?.message == message { return }
        end()
        let handle = center.show(CmuxToast(id: request.id, message: message, duration: request.duration),
                                                 in: window)
        // Every end clears the model, eviction by the stack limit too; deferred, so the
        // model never changes inside the toast center's or SwiftUI's update.
        let onDismiss = request.onDismiss
        handle.onDismiss = { _ in
            // task-owner: one main-actor hop that clears the model once; nothing to cancel
            Task { @MainActor in onDismiss() }
        }
        shown = (message, handle)
    }

    /// The view is going away: end its toast, and clear the model too, so a
    /// reopened panel does not replay an old message.
    func dismantle() {
        let onDismiss = request?.message != nil ? request?.onDismiss : nil
        request = nil
        // task-owner: one main-actor hop that clears the model once; nothing to cancel
        if let onDismiss { Task { @MainActor in onDismiss() } }
    }

    /// Ends the toast showing, if any, without telling the model (its
    /// message is gone or changed).
    private func end() {
        guard let shown else { return }
        self.shown = nil
        shown.handle.onDismiss = nil
        shown.handle.dismiss()
    }
}
