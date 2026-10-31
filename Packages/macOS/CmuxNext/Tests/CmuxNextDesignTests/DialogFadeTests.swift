import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// POLISH (no flash): a window dialog and its scrim appeared in one frame, so the whole window
/// darkened at once. Both fade in (the card on the fade-in token, the scrim on the scrim token),
/// which Reduce Motion keeps; the card also grows in on the `appear` spring, which it drops.
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

    /// Alert polish (debug.dialog_strip): in about half the opens, base build included, the window
    /// server showed the whole dialog and scrim for one frame before the fade began: attaching the
    /// overlay panel displays and commits its layers at full opacity. When the panel attaches, the
    /// card and scrim are already transparent.
    @Test func theOverlayPanelAttachesWithTheDialogStillTransparent() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.closeWithOverlayHost() }
        let host = WindowOverlayHost.host(for: window)
        let dialog = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
        var seen: [Float] = []
        host.onPanelChange = { [weak host] in
            guard let host, host.isPanelAttached, seen.isEmpty else { return }
            let container = host.panel.container(for: .modal)
            seen = ([dialog] + container.subviews.filter { $0 is OverlayScrimView }).map { $0.layer?.opacity ?? 1 }
        }
        defer { host.onPanelChange = nil }
        let handle = host.present(dialog, options: OverlayOptions(kind: .dialog, isModal: true, dimsContent: true,
                                                                  passesThroughClicks: false))
        defer { handle.dismiss() }
        #expect(!seen.isEmpty, "the panel never attached")
        #expect(seen.allSatisfy { $0 == 0 }, "the panel attached with the dialog showing: \(seen)")
    }

    /// Alert polish (debug.dialog_strip): a panel ordered out the turn its last dialog left kept that
    /// dialog's drawn surface, and the next attach showed it for a frame before its own content drew
    /// (2 opens in 10 when the panel attached fresh, none while it stayed attached). The panel stays
    /// until the frame that draws it empty has committed, then leaves; an overlay presented in
    /// between keeps it (no detach), and it shows at once on every attach (never hidden).
    @Test func thePanelLeavesOnlyAfterItsEmptyFrameAndAReattachCancelsTheDetach() async throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.closeWithOverlayHost() }
        let host = WindowOverlayHost.host(for: window)
        // Still the window's child window: the panel is on screen (its surface can show).
        let onWindow = { window.childWindows?.contains { $0 === host.panel } == true }
        let toast = OverlayOptions(kind: .toast, isModal: false, dimsContent: false, passesThroughClicks: true)
        let first = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 30)), options: toast)
        #expect(host.isPanelAttached && onWindow() && host.panel.alphaValue == 1)
        first.dismiss()
        #expect(!host.isPanelAttached, "the host kept using a panel nothing needs")
        #expect(onWindow(), "the panel left in the turn its content did, with its old surface")
        // Presented again before that commit: the panel never leaves.
        let second = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 30)), options: toast)
        #expect(host.isPanelAttached)
        await Self.nextTurns()
        #expect(host.isPanelAttached && onWindow(), "a pending detach took the panel from under a new overlay")
        second.dismiss()
        await Self.nextTurns()
        #expect(!onWindow(), "the panel never left after its empty frame")
        let third = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 30)), options: toast)
        defer { third.dismiss() }
        #expect(host.isPanelAttached && onWindow() && host.panel.alphaValue == 1, "an attach hid the panel")
    }

    /// Waits until two main run-loop passes have committed, so any after-commit work the
    /// dismissal or present scheduled has run: the signal `AfterFrameCommit` uses, a one-shot
    /// before-waiting observer after every other observer of the pass (Core Animation's commit runs
    /// before it), then a wakeup so the next pass runs.
    private static func nextTurns() async {
        for _ in 0..<2 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                                  false, CFIndex.max) { _, _ in
                    done.resume()
                    CFRunLoopWakeUp(CFRunLoopGetMain())
                }
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
            }
        }
    }

    /// Alert polish (2026-10-28, debug.dialog_strip): the card only faded, flat, while the palette
    /// grows in. It now grows from `Motion.panelOpenScale` about its center on the `appear` spring;
    /// under Reduce Motion it only fades (the scale applies at once).
    @Test func aDialogCardGrowsInFromThePanelScaleUnlessReduceMotion() throws {
        for reduce in [false, true] {
            Motion.reduceMotionOverride = reduce
            defer { Motion.reduceMotionOverride = nil }
            let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            defer { window.closeWithOverlayHost() }
            let host = WindowOverlayHost.host(for: window)
            let dialog = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
            let handle = host.present(dialog, options: OverlayOptions(kind: .dialog, isModal: true, dimsContent: true,
                                                                      passesThroughClicks: false))
            defer { handle.dismiss() }
            let layer = try #require(dialog.layer)
            #expect(CATransform3DIsIdentity(layer.sublayerTransform), "the card ends at its full size")
            let grow = layer.animation(forKey: "sublayerTransform") as? CASpringAnimation
            if reduce {
                #expect(grow == nil, "Reduce Motion: the card fades, it does not grow")
            } else {
                let from = try #require((grow?.fromValue as? NSValue)?.caTransform3DValue)
                let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
                #expect(CATransform3DEqualToTransform(from, Motion.scale(Motion.panelOpenScale, about: center, in: layer)))
            }
            #expect((layer.animation(forKey: "opacity") as? CABasicAnimation)?.fromValue as? NSNumber == 0)
        }
    }

    /// Alert polish: the card's overlay panel gives key back as the close starts, and the glass took
    /// its inactive grey frost: the card lit up a lighter grey for the whole fade (the close's first
    /// frame was further from both the open and the closed dialog than they are from each other).
    /// The card's glass keeps the key-window look.
    @Test func aDialogCardKeepsTheKeyWindowGlass() throws {
        let dialog = CmuxDialogView(spec: CmuxDialogSpec(title: "Close Workspace?", buttons: [.cancel(), .ok()]),
                                    activeLook: ActiveLookScope())
        func glass(in view: NSView) -> [GlassPanelView] {
            (view as? GlassPanelView).map { [$0] } ?? view.subviews.flatMap(glass(in:))
        }
        let surface = try #require(dialog.surface)
        for panel in glass(in: surface) { #expect(panel.keepsActiveLook, "the dialog's glass frosts grey when its panel gives key back") }
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
        #expect(CATransform3DIsIdentity(try #require(dialog.layer).sublayerTransform), "a dialog shown again starts at its full size")
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
