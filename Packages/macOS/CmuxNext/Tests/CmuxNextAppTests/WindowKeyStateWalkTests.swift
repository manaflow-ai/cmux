import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextTestSupport
import Testing

/// NEWTAB DEVTOOLS FRAMES (key turn): Cmd-T from a terminal gives the keys to the New Tab page's Chromium page window,
/// a child of the cmux window. AppKit then walks the cmux window's whole view tree for its key change
/// (`_windowChangedKeyState`), and every button, text field and split view lays out and redraws again: 11 ms of layout
/// and 5 ms of display in the key's commit (profile ndf-kt-prof-head0, cmux24, three presses). The window does not look
/// different: its page window, popups and sheets are its family and never make it look inactive (WindowKeyFamily), and
/// it stays the main window. A key-state notice that leaves the family's key state as it was walks no content view.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct WindowKeyStateWalkTests {
    /// A content view that counts AppKit's key-state walks that reach it.
    final class Probe: NSView {
        var walks = 0

        @objc(_windowChangedKeyState)
        func probeWindowChangedKeyState() { walks += 1 }
    }

    static let walk = NSSelectorFromString("_windowChangedKeyState")

    /// One main run loop pass: blocks queued before this one have run.
    static func runLoopPass() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            MainRunLoopBlock.perform { done.resume() }
        }
    }

    @Test func aKeyStateNoticeThatLeavesTheFamilysKeyStateWalksNoContentView() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            try await PasswordManagerRouteTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let window = try #require(services.windows.active?.window)
            let root = try #require(window.contentView)
            try #require(root.responds(to: Self.walk), "AppKit has no key-state walk on this macOS")
            let probe = Probe(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            root.addSubview(probe)
            defer { probe.removeFromSuperview() }
            // The first notice brings the content to the family's key state; the next one, with nothing changed (the
            // keyboard moved between the window and a window of its family), must walk nothing.
            root.perform(Self.walk)
            await Self.runLoopPass()
            let settled = probe.walks
            root.perform(Self.walk)
            await Self.runLoopPass()
            root.perform(Self.walk)
            await Self.runLoopPass()
            #expect(probe.walks == settled, "\(probe.walks - settled) content walks for key-state notices that changed nothing")
        }
    }
}
