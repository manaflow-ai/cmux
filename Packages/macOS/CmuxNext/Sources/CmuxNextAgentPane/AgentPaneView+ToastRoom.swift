public import AppKit
public import CmuxNextDesign

/// A toast never covers the chat (Leo, 2026-11-06: "why is this still happening yo", a machine
/// toast drawn over his queued prompt in an agent chat). Toasts rest bottom-center over the window,
/// over this pane's foot, where its composer and queued prompts float; the pane gives the page the
/// band they take (`__cmuxToastRoom`, webviews toastRoom.ts), and the page keeps its stage and
/// bottom stack above it.
extension AgentPaneView: CmuxToastReserving {
    public func toastsSettled(in rect: NSRect?, duration: TimeInterval) {
        let pane = window == nil ? NSRect.zero : convert(bounds, to: nil)
        let room = Self.toastRoom(toasts: rect, pane: pane) / max(uiPointerPageZoom, 0.01)
        let script = "globalThis.__cmuxToastRoom?.(\(room.isFinite ? room : 0));"
        if let page { page.evaluate(script) } else { webView.evaluateJavaScript(script, completionHandler: nil) }
    }

    /// The gap between the toasts' top and the chat above them.
    static let toastRoomGap: CGFloat = 8

    /// The band at the foot of `pane` (window coordinates) that toasts in `toasts` take, in view
    /// points: from the pane's bottom to the toasts' top and a gap; 0 when no toast lies over the
    /// pane. Never more than half the pane, so a short pane keeps its chat.
    static func toastRoom(toasts: NSRect?, pane: NSRect) -> CGFloat {
        guard let toasts, !toasts.isEmpty, !pane.isEmpty,
              toasts.maxX > pane.minX, toasts.minX < pane.maxX,
              toasts.minY < pane.maxY, toasts.maxY > pane.minY else { return 0 }
        return min(pane.height / 2, toasts.maxY + toastRoomGap - pane.minY)
    }
}
