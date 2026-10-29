import AppKit
@testable import CmuxNextDesign
import Testing

/// POLISH audit, batch 3 (cx-2grmt): a page's menu shown past its window's edge (a `<select>`,
/// WebPopupHost) drew the system window shadow and appeared and left in one frame. It casts the
/// one popup shadow (`PopupStyle`, like the page's own menus) and opens and closes like every
/// native popup (`openPopup` / `closePopup`).
@MainActor @Suite(.serialized) struct PagePopupMotionTests {
    /// Popup motion is observable only on an awake display with animations enabled. The tests pin
    /// Reduce Motion off around the operation, so the system Reduce Motion setting does not gate
    /// this predicate.
    @Test(.enabled("needs an awake display and animations on, or every popup snaps anyway") { await GUIAnimationTestSupport.animatesHere() })
    func aPageMenuCastsThePopupShadowAndOpensAndClosesWithMotion() async throws {
        let (window, page) = try Self.page()
        defer { window.orderOut(nil) }
        let host = WebPopupHost(webView: page, zoom: { 1 }, send: { _ in })
        // Opening is synchronous; the close may animate. The override is process-wide.
        let (reply, panel, opened) = try { () throws -> ([String: Any], WebPopupPanel, Bool) in
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }
            let reply = host.show(try Self.menu(["a", "b"]))
            let panel = try #require(NSApp.windows.compactMap { $0 as? WebPopupPanel }.first { $0.parent === window })
            return (reply, panel, panel.contentView?.layer?.animationKeys()?.isEmpty ?? true)
        }()
        #expect(!panel.hasShadow, "the system window shadow")
        let card = try #require(panel.contentView as? PopupHostView, "no popup shadow").card
        // The reply and `shownFrame` name the menu's card, not its shadow band.
        let frame = try #require(reply["frame"] as? [CGFloat])
        #expect(host.shownFrame == CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]))
        #expect(host.shownFrame?.size == card.frame.size)
        #expect(opened, "the menu animated in")

        host.hide()
        #expect(panel.isVisible, "closed in one frame")
        #expect(await GUIAnimationTestSupport.settle { !panel.isVisible }, "the close never ended")
    }

    static func menu(_ ids: [String], instant: Bool? = nil) throws -> WebPopupHost.Model {
        var params: [String: Any] = [
            "items": ids.map { ["id": $0, "label": $0] },
            "anchor": ["left": 40, "top": 40, "right": 200, "bottom": 64], "width": 160,
        ]
        if let instant { params["instant"] = instant }
        return try #require(WebPopupHost.Model(params))
    }

    /// Leo 2026-10-22, no entry animations on the New Tab: its menus ask for none (`instant: true`).
    @Test func theInstantFlagIsReadFromThePageRequest() throws {
        #expect(try Self.menu(["a"], instant: true).instant)
        #expect(try !Self.menu(["a"]).instant)
        #expect(try !Self.menu(["a"], instant: false).instant)
    }

    /// No entrance asked: the card shows whole in one frame, and its close still fades.
    @Test(.enabled("needs an awake display and animations on, or every popup snaps anyway") { await GUIAnimationTestSupport.animatesHere() })
    func anInstantPageMenuOpensInOneFrameAndStillFadesOut() async throws {
        let (window, page) = try Self.page()
        defer { window.orderOut(nil) }
        let host = WebPopupHost(webView: page, zoom: { 1 }, send: { _ in })
        let (panel, opening, opacity) = try { () throws -> (WebPopupPanel, [String], Float?) in
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }
            host.show(try Self.menu(["a", "b"], instant: true))
            let panel = try #require(NSApp.windows.compactMap { $0 as? WebPopupPanel }.first { $0.parent === window })
            let layer = panel.contentView?.layer
            return (panel, ["opacity", "sublayerTransform"].filter { layer?.animation(forKey: $0) != nil }, layer?.opacity)
        }()
        #expect(opening == [], "the menu animated in")
        #expect(opacity == 1)
        #expect(panel.alphaValue == 1)

        Motion.reduceMotionOverride = false
        host.hide()
        let closing = panel.contentView?.layer?.animation(forKey: "opacity") != nil
        Motion.reduceMotionOverride = nil
        #expect(closing, "the close lost its fade")
        #expect(await GUIAnimationTestSupport.settle { !panel.isVisible }, "the close never ended")
    }

    /// Native menus and popovers use the host's default: no entrance motion.
    @Test(.enabled("needs an awake display and animations on, or every popup snaps anyway") { await GUIAnimationTestSupport.animatesHere() })
    func aNativePopupDefaultsToAnInstantOpenAndFadesOnClose() async throws {
        let (window, _) = try Self.page()
        defer { window.orderOut(nil) }
        let panel = NativePopupPanel(identifier: "cmux.tests.instant-popup")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
        content.wantsLayer = true
        panel.contentView = content
        let host = NativePopupHost(panel: panel)
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }

        _ = try #require(host.show(size: content.frame.size,
                                   anchor: CGRect(x: 300, y: 580, width: 24, height: 24),
                                   in: window))
        #expect(content.layer?.animation(forKey: "opacity") == nil, "the popup fades in")
        #expect(content.layer?.animation(forKey: "sublayerTransform") == nil, "the popup grows in")
        #expect(content.layer?.opacity == 1)

        host.hide()
        #expect(content.layer?.animation(forKey: "opacity") != nil, "the popup lost its close fade")
        #expect(await GUIAnimationTestSupport.settle { !panel.isVisible }, "the close never ended")
    }

    /// A window on screen with a page view, and the page menu panel of `host` once shown.
    static func page() throws -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 500, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = page
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        return (window, page)
    }

    /// Review of #19944: the page posts an update for the menu it is still closing (a highlight
    /// as Base UI closes it) after the menu went away here. It must not open again.
    @Test(.enabled("needs an awake display and animations on, or every popup snaps anyway") { await GUIAnimationTestSupport.animatesHere() })
    func anUpdateDuringTheCloseDoesNotReopenTheMenu() async throws {
        let (window, page) = try Self.page()
        defer { window.orderOut(nil) }
        let host = WebPopupHost(webView: page, zoom: { 1 }, send: { _ in })
        host.show(try Self.menu(["a", "b"]))
        let panel = try #require(NSApp.windows.compactMap { $0 as? WebPopupPanel }.first { $0.parent === window })
        host.hide()
        host.update(try Self.menu(["a", "b", "c"]))
        #expect(await GUIAnimationTestSupport.settle { !panel.isVisible }, "the closed menu opened again")
        #expect(host.shownFrame == nil)
    }

    /// Review of #19944: the page's view goes (its tab closed) while its menu fades out. The menu
    /// still leaves its window.
    @Test(.enabled("needs an awake display and animations on, or every popup snaps anyway") { await GUIAnimationTestSupport.animatesHere() })
    func aMenuWhoseHostGoesMidFadeStillLeaves() async throws {
        let (window, page) = try Self.page()
        defer { window.orderOut(nil) }
        var host: WebPopupHost? = WebPopupHost(webView: page, zoom: { 1 }, send: { _ in })
        weak var gone = host
        host?.show(try Self.menu(["a", "b"]))
        let panel = try #require(NSApp.windows.compactMap { $0 as? WebPopupPanel }.first { $0.parent === window })
        host?.hide()
        host = nil
        #expect(gone == nil)
        #expect(await GUIAnimationTestSupport.settle { !panel.isVisible }, "a dead host's menu stayed on its window")
        #expect(panel.parent == nil)
    }
}
