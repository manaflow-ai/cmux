import AppKit
@testable import CmuxNextBrowser
import Testing

/// A remote Cocoa page stays at its pane's top while the pane's size changes in a live resize.
///
/// The boundary: Chromium's remote_cocoa bridge, which runs in this process, places the page's
/// `WebContentsViewCocoa` in ``ChromiumHostPageView/remoteContainer`` from the host's top-left Views bounds
/// (`WebContentsNSViewBridge::SetBounds`, content/app_shim_remote_cocoa/web_contents_ns_view_bridge.mm). For an
/// unflipped superview it turns Y around with `superview_height`, the host's content rect, and the host keeps the
/// height from before a live resize until the resize ends. The bridge's placement is replayed here as Chromium 157
/// does it; the views are the app's own. Measured before the fix (approaches/remote-cocoa cause.json): the whole
/// page moved by its pane's height change since the press (slope 0.50 of the window's height change, the pane's share
/// of it; r 1.00), content low while the pane grew and cut at the top while it shrank.
@MainActor @Suite
struct ChromiumRemotePagePinTests {
    /// One live resize step: the pane's new size, and the content rect height the host still flips with.
    struct Step: CustomTestStringConvertible, Sendable {
        let width: CGFloat, height: CGFloat, hostContentHeight: CGFloat
        var testDescription: String { "pane \(Int(width))x\(Int(height)), host content rect \(Int(hostContentHeight))" }
    }

    static let rest = NSSize(width: 480, height: 300)

    /// `WebContentsNSViewBridge::SetBounds(bounds_in_superview, superview_height)` (Chromium 157).
    static func bridgeSetBounds(_ page: NSView, _ bounds: CGRect, superviewHeight: CGFloat) {
        let flipped = page.superview?.isFlipped == true
        let y = flipped ? bounds.minY : superviewHeight - bounds.minY - bounds.height
        page.frame = NSRect(x: bounds.minX, y: y, width: bounds.width, height: bounds.height)
    }

    /// The page's top edge and its pane's, in the pane's coordinates (unflipped: larger y is higher).
    static func tops(_ page: NSView, in pane: NSView) -> (page: CGFloat, pane: CGFloat) {
        (pane.convert(page.bounds, from: page).maxY, pane.bounds.maxY)
    }

    @Test(arguments: [
        Step(width: 480, height: 340, hostContentHeight: 300),  // the pane grows, the host flips with its old height
        Step(width: 480, height: 420, hostContentHeight: 300),
        Step(width: 480, height: 260, hostContentHeight: 300),  // the pane shrinks
        Step(width: 480, height: 180, hostContentHeight: 300),
        Step(width: 360, height: 300, hostContentHeight: 322),  // a width change with a content rect that disagrees
        Step(width: 480, height: 340, hostContentHeight: 340),  // the host caught up
    ])
    func thePageStaysAtItsPanesTop(step: Step) {
        let pane = NSView(frame: NSRect(origin: .zero, size: Self.rest))
        let view = ChromiumHostPageView(frame: pane.bounds)
        pane.addSubview(view)
        view.remoteCocoa = true
        let page = NSView()  // stands in for the page's WebContentsViewCocoa, which the bridge places
        view.remoteContainer.addSubview(page)
        Self.bridgeSetBounds(page, CGRect(origin: .zero, size: Self.rest), superviewHeight: Self.rest.height)
        let atRest = Self.tops(page, in: pane)
        #expect(atRest.page == atRest.pane)

        // The pane takes its new size; the host lays the page out at that size and flips with its content rect.
        pane.setFrameSize(NSSize(width: step.width, height: step.height))
        Self.bridgeSetBounds(page, CGRect(x: 0, y: 0, width: step.width, height: step.height),
                             superviewHeight: step.hostContentHeight)
        let during = Self.tops(page, in: pane)
        #expect(during.page == during.pane, "the page's top is \(during.page - during.pane) pt off its pane's top")
        #expect(view.remoteContainer.frame.size == pane.bounds.size)
    }
}
