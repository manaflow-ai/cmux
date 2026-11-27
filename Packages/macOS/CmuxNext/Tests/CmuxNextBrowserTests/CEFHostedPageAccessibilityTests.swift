import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Testing

/// customize-composer-nightly: "In the newest cmux NEXT Nightly, a person opens Customize from the app menu, asks its
/// composer for a change, and the change shows in the running app with no relaunch." The probe found no AXComboBox
/// "Prompt" in any window: a hosted page's accessibility tree lives in Chromium's embedded page window, which is no
/// AXWindow of the app (`ax_window_unresolved`), and nothing under the cmux window led to it. The hosted page view now
/// lends the page window's content as its accessibility children.
@MainActor
@Suite(.serialized, .closesItsWindows) struct CEFHostedPageAccessibilityTests {
    final class StandInPageWindow: NSWindow {
        @objc dynamic func isEmbeddedInParentView() -> Bool { true }
    }

    static let content = CGRect(x: 200, y: 200, width: 800, height: 500)

    func makeHost() -> (NSWindow, CEFHostedPageView) {
        let window = NSWindow(contentRect: Self.content, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = CEFHostedPageView(frame: window.contentView!.bounds, makeLayerHost: { _ in CALayer() })
        window.contentView!.addSubview(page)
        return (window, page)
    }

    func makePageWindow(at frame: CGRect) -> (NSWindow, NSButton) {
        let page = StandInPageWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        let prompt = NSButton(title: "Prompt", target: nil, action: nil)
        page.contentView!.addSubview(prompt)
        return (page, prompt)
    }

    @Test func aHostedPageReadsItsPageWindowsTreeUnderTheCmuxWindow() {
        let (window, hosted) = makeHost()
        let (page, prompt) = makePageWindow(at: Self.content)
        window.addChildWindow(page, ordered: .above)
        #expect(hosted.pageWindowForAccessibility() === page)
        #expect(hosted.isAccessibilityElement())
        #expect((hosted.accessibilityChildren() ?? []).contains { ($0 as AnyObject) === prompt },
                "the page's elements read nowhere an AX client walks from the cmux window")
        page.close()
        window.close()
    }

    @Test func aDetachedPageWindowStillLendsItsTree() {
        let (window, hosted) = makeHost()
        let (page, prompt) = makePageWindow(at: Self.content)
        #expect(hosted.pageWindowForAccessibility(appWindows: { [window, page] }) === page)
        _ = prompt
        page.close()
        window.close()
    }

    @Test func noPageWindowHereLendsNothing() {
        let (window, hosted) = makeHost()
        let (elsewhere, _) = makePageWindow(at: Self.content.offsetBy(dx: 300, dy: 0))
        window.addChildWindow(elsewhere, ordered: .above)
        let (plain, _) = makePageWindow(at: Self.content)
        #expect(hosted.pageWindowForAccessibility(isEmbedded: { $0 === elsewhere }, appWindows: { [plain] }) == nil)
        #expect(hosted.pageWindowForAccessibility(appWindows: { [] }) == nil)
        #expect(!hosted.isAccessibilityElement() || hosted.pageWindowForAccessibility() != nil)
        elsewhere.close()
        plain.close()
        window.close()
    }
}
