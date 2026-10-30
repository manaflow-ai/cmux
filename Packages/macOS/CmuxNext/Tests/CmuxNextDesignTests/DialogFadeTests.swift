import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// POLISH (no flash): a window dialog and its scrim appeared in one frame, so the whole window
/// darkened at once. Both fade in with the fade-in token, which Reduce Motion keeps.
@MainActor @Suite(.serialized, .closesItsWindows) struct DialogFadeTests {
    /// The close fades need an awake display with animations enabled: in a window with no screen
    /// or with motion off a change applies at once (`Motion.canAnimate`), so these tests run only
    /// where the fade can be observed.
    @Test func aDialogAndItsScrimFadeInInsteadOfAppearingInOneFrame() throws {
        // Synchronous from here to the reset: the override is process-wide.
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.closeWithOverlayHost() }
        let host = WindowOverlayHost.host(for: window)
        let dialog = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
        let handle = host.present(dialog, options: OverlayOptions(kind: .dialog, isModal: true, dimsContent: true,
                                                                  passesThroughClicks: false))
        defer { handle.dismiss() }
        let container = host.panel.container(for: handle.options.effectiveLayer)
        let scrim = try #require(container.subviews.first { $0 is OverlayScrimView })
        for (name, view) in [("scrim", scrim), ("dialog", dialog)] {
            let fade = view.layer?.animation(forKey: "opacity") as? CABasicAnimation
            #expect((fade?.fromValue as? NSNumber)?.floatValue == 0, "\(name) appeared in one frame")
            #expect(view.layer?.opacity == 1, "\(name)")
        }
    }

    /// Batch 2 (cx-2grmt): the close was still one frame. The dialog and its scrim stay where they
    /// were while they fade out, and the window takes input at once.
    @Test(.enabled("needs an awake display and animations on, or the dialog snaps anyway") { await GUIAnimationTestSupport.animatesHere() }) func aClosedDialogAndItsScrimFadeOutThenGo() async throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        // On screen, as a dialog's window is: a change in a window with no screen applies at once.
        window.orderFrontRegardless()
        defer { window.closeWithOverlayHost() }
        try #require(window.screen != nil)
        let host = WindowOverlayHost.host(for: window)
        let dialog = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
        let handle = host.present(dialog, options: OverlayOptions(kind: .dialog, isModal: true, dimsContent: true,
                                                                  passesThroughClicks: false))
        let container = host.panel.container(for: handle.options.effectiveLayer)
        let scrim = try #require(container.subviews.first { $0 is OverlayScrimView })

        handle.dismiss()
        #expect(host.presentedHandles.isEmpty)
        #expect(!host.blocksWholeWindow, "the window waits for the fade")
        #expect(dialog.superview != nil, "the dialog vanished in one frame")
        #expect(scrim.superview != nil, "the scrim vanished in one frame")

        #expect(await GUIAnimationTestSupport.settle { host.fadingOut == 0 }, "the fade out never ended")
        #expect(dialog.superview == nil)
        #expect(scrim.superview == nil)
        #expect(dialog.alphaValue == 1, "a dialog shown again starts whole")
    }

    /// Review of #19938: a tab's dialog follows its tab to another window (the old window's host
    /// lets it go, the new one shows it). The old host's fade must not take it out of the new window.
    @Test(.enabled("needs an awake display and animations on, or the dialog snaps anyway") { await GUIAnimationTestSupport.animatesHere() }) func aDialogMovedToAnotherWindowMidFadeStaysThere() async throws {
        let first = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 300), styleMask: [.titled],
                             backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 650, y: 400, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        for window in [first, second] { window.orderFrontRegardless() }
        defer { for window in [first, second] { window.closeWithOverlayHost() } }
        try #require(first.screen != nil && second.screen != nil)
        let options = OverlayOptions(kind: .dialog, isModal: true, dimsContent: true, passesThroughClicks: false)
        let dialog = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
        WindowOverlayHost.host(for: first).present(dialog, options: options).dismiss()
        let moved = WindowOverlayHost.host(for: second).present(dialog, options: options)
        defer { moved.dismiss() }

        let old = WindowOverlayHost.host(for: first)
        #expect(await GUIAnimationTestSupport.settle { old.fadingOut == 0 }, "the old window's fade never ended")
        #expect(dialog.window === WindowOverlayHost.host(for: second).panel, "the old window's fade took the dialog")
        #expect(dialog.alphaValue == 1)
    }

    /// Review of #19938: a closing dialog keeps no keyboard focus while it fades, so a Return in
    /// the fade cannot press its button again.
    @Test(.enabled("needs an awake display and animations on, or the dialog snaps anyway") { await GUIAnimationTestSupport.animatesHere() }) func aClosingDialogGivesUpTheKeyboard() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.orderFrontRegardless()
        defer { window.closeWithOverlayHost() }
        try #require(window.screen != nil)
        let host = WindowOverlayHost.host(for: window)
        let dialog = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 120, height: 24))
        dialog.addSubview(field)
        let handle = host.present(dialog, options: OverlayOptions(kind: .dialog, isModal: true, dimsContent: true,
                                                                  passesThroughClicks: false))
        host.panel.makeFirstResponder(field)
        handle.dismiss()
        let responder = host.panel.firstResponder as? NSView
        #expect(responder.map { !$0.isDescendant(of: dialog) } ?? true, "the fading dialog kept the keyboard")
    }
}
