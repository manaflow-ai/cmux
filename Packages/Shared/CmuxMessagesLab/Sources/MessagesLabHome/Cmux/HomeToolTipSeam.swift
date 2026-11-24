// cmux: the synchronous seam from the transcript's nonisolated controllers into the host's main-actor tooltip. Not a
// vendored file.
import AppKit

/// One control's tooltip, set through the host's ``MessagesLabHomeHost/showToolTip`` from code that is not main-actor
/// isolated (ChatController, HeaderBar), as AppKit's `toolTip` was; off the main thread it sets nothing.
struct HomeToolTipSeam {
    let view: NSView

    func set(_ text: String?) {
        guard Thread.isMainThread else { return }
        let view = view
        // main-proof: guarded by Thread.isMainThread above; the transcript's views are made and laid out on the main thread.
        MainActor.assumeIsolated { MessagesLabHomeView.host.showToolTip(view, text?.isEmpty == false ? text : nil) }
    }
}
