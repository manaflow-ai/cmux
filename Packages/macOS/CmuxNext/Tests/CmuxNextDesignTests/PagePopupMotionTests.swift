import AppKit
@testable import CmuxNextDesign
import Testing

/// POLISH audit, batch 3 (cx-2grmt): a page's menu shown past its window's edge (a `<select>`,
/// WebPopupHost) drew the system window shadow and appeared and left in one frame. It casts the
/// one popup shadow (`PopupStyle`, like the page's own menus) and opens and closes like every
/// native popup (`openPopup` / `closePopup`).
@MainActor @Suite(.serialized) struct PagePopupMotionTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aPageMenuCastsThePopupShadowAndOpensAndClosesWithMotion() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 500, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try #require(window.screen != nil)
        let host = WebPopupHost(webView: page, zoom: { 1 }, send: { _ in })
        let model = try #require(WebPopupHost.Model([
            "items": [["id": "a", "label": "Apple"], ["id": "b", "label": "Banana"]],
            "anchor": ["left": 40, "top": 40, "right": 200, "bottom": 64], "width": 160,
        ]))

        let reply = host.show(model)
        let panel = try #require(NSApp.windows.compactMap { $0 as? WebPopupPanel }.first { $0.parent === window })
        #expect(!panel.hasShadow, "the system window shadow")
        let card = try #require(panel.contentView as? PopupHostView, "no popup shadow").card
        // The reply and `shownFrame` name the menu's card, not its shadow band.
        let frame = try #require(reply["frame"] as? [CGFloat])
        #expect(host.shownFrame == CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]))
        #expect(host.shownFrame?.size == card.frame.size)
        #expect(panel.contentView?.layer?.animation(forKey: "sublayerTransform") != nil, "opened in one frame")

        host.hide()
        #expect(panel.isVisible, "closed in one frame")
        try await Task.sleep(for: .milliseconds(600))
        #expect(!panel.isVisible)
    }
}
