import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
import Testing

/// Lawrence (hmdm7 shots, 2026-10-08): a toast ("Recovered unsaved changes
/// in main.ts (src)  Open  X") sat on the Home composer's "+" button. A toast
/// never covers the composer or its buttons: it goes above the composer, at
/// every Home width, the narrowest too.
@MainActor @Suite(.serialized) struct HomeToastPlacementTests {
    @Test(arguments: [628.0, 360.0])
    func aToastNeverCoversTheComposer(width: Double) async throws {
        let (window, view, _) = await HomeFirstRunTests.view()
        defer { window.close() }
        window.setContentSize(NSSize(width: width, height: 700))
        view.frame = window.contentView?.bounds ?? .zero
        view.layoutSubtreeIfNeeded()
        let toastView = CmuxToastView(toast: CmuxToast(id: "recovered", message: "Recovered unsaved changes in main.ts (src)",
                                                       action: .init(title: "Open")))
        let host = CmuxToastOverlayHost()
        host.show(toastView, in: window, slot: 0, windowGone: {})
        defer { host.hide(toastView) }
        toastView.layoutSubtreeIfNeeded()
        // Overlay panel coordinates are the window's own.
        let toast = toastView.frame
        let fieldTop = view.transcript.fieldTop
        let composer = view.convert(NSRect(x: 0, y: fieldTop, width: view.bounds.width, height: view.bounds.height - fieldTop), to: nil)
        #expect(toast.height > 0)
        #expect(!toast.intersects(composer), "the toast \(toast) covers the composer \(composer) at width \(width)")
    }
}
