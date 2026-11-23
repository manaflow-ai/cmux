import AppKit
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFocusUI
import CmuxNextTestSupport
import Foundation
import Testing

/// What in-tree pages retire, and what they must not (plans/cmux-next/in-tree-pages.md). With the mode on a page is a view
/// of its cmux window, so the paths that guarded a Chromium page child window are retired (`InTreeRetiredGuards` counts
/// any that still act). Separate windows still exist in the mode: several cmux windows, a `window.open` popup's own cmux
/// window, sheets and popover hosts. The guards keep their protection for those, and only a real Chromium page window
/// (`CefNSWindow`) counts as a page window.
@MainActor @Suite(.closesItsWindows, .serialized) struct InTreeRetiredGuardsTests {
    private struct Harness {
        let services: AppServices
        let a: WindowController
        let b: WindowController

        func close() {
            for controller in services.windows.controllers { controller.window?.close() }
            AppHarnessWindows.closeThoseThisTestOpened()
        }
    }

    private static func harness() throws -> Harness {
        var completed = false
        defer {
            if !completed { AppHarnessWindows.closeThoseThisTestOpened() }
        }
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let a = try #require(services.windows.openWindow(workspaces: ["itg-a1"]))
        let b = try #require(services.windows.openWindow(workspaces: ["itg-b1"]))
        completed = true
        return Harness(services: services, a: a, b: b)
    }

    private static func window(_ type: NSWindow.Type = NSWindow.self) -> NSWindow {
        let window = type.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                               backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A view that takes the keyboard.
    final class Field: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// With in-tree pages on, a key typed into cmux window A that would reach cmux window B (a late `makeKey`, a stale
    /// key record) is still dropped by the app's last check, as with the mode off: the mode removed page windows, not
    /// cmux windows. Only a key that involves a Chromium page window (none should exist in the mode) is left to go on,
    /// and counted.
    @Test func aKeyCrossingCmuxWindowsIsDroppedWithInTreePagesOn() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let shellA = try #require(harness.a.window), shellB = try #require(harness.b.window)
        let router = harness.services.keyRouter
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: nil) }
        try #require(InTreePages.shared.isActive)
        #expect(CrossWindowInputGuard.drops(keyTypedInto: shellA, keyWindow: shellB, router: router),
                "in tree, a key typed in window A reached window B")
        #expect(CrossWindowInputGuard.drops(keyTypedInto: shellB, keyWindow: shellA, router: router),
                "in tree, a key typed in window B reached window A")
        #expect(!CrossWindowInputGuard.drops(keyTypedInto: shellA, keyWindow: shellA, router: router))
        // A Chromium page window (the retired case): not judged in the mode, and counted.
        let page = Self.window(try WindowHoldsKeyboardTests.pageWindowClass())
        shellA.addChildWindow(page, ordered: .above)
        defer { shellA.removeChildWindow(page); page.close() }
        let before = InTreeRetiredGuards.shared.crossWindowInput
        #expect(!CrossWindowInputGuard.drops(keyTypedInto: page, keyWindow: shellB, router: router),
                "in tree, the retired page-window case was judged")
        #expect(InTreeRetiredGuards.shared.crossWindowInput == before + 1, "a key the retired case would have dropped was not counted")
    }

    /// The responder gate counts a refused move to an unseen view as the retired page-window branch only when the view is
    /// in a Chromium page window: a sheet or popover host is a child window too, and its refusal is not a page window's.
    @Test func onlyAChromiumPageWindowCountsAsAPageWindowInTheGate() throws {
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: nil) }
        try #require(InTreePages.shared.isActive)
        let parent = Self.window()
        defer { parent.close() }
        func refusal(in host: NSWindow) throws -> Int {
            parent.addChildWindow(host, ordered: .above)
            defer { parent.removeChildWindow(host); host.close() }
            try #require(host.parent === parent, "AppKit did not keep the child window's parent")
            let content = try #require(host.contentView)
            let shown = Field(frame: NSRect(x: 0, y: 0, width: 200, height: 300)), hidden = Field(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
            hidden.isHidden = true
            content.addSubview(shown)
            content.addSubview(hidden)
            host.makeFirstResponder(shown)
            try #require(host.firstResponder === shown)
            let before = InTreeRetiredGuards.shared.unseenKeyboardPageWindow
            let gate = ResponderMoveGate(window: host, log: nil, inInputEvent: false, focusModelApplies: false)
            #expect(gate.refuses(hidden, or: { false }), "the gate let the keyboard move to an unseen view")
            return InTreeRetiredGuards.shared.unseenKeyboardPageWindow - before
        }
        #expect(try refusal(in: Self.window()) == 0, "a sheet or popover host's refusal counted as a page window's")
        #expect(try refusal(in: Self.window(try WindowHoldsKeyboardTests.pageWindowClass())) == 1,
                "a Chromium page window's refusal was not counted")
    }
}
