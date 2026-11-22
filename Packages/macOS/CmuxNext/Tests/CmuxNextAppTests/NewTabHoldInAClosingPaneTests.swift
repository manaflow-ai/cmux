#if DEBUG
import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesignTokens
import CmuxNextFocusUI
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Foundation
import Testing

/// A pane close that moves its panes keeps the closed pane in the window, shown, to the end of the move, and the
/// pane that takes its room grows over it. In that time 2 panes are at one place, and the app told Chromium for
/// each that its page shows. A New Tab key in that time opens the key hold in the pane that stays. The hold and its
/// replay ask which agent pane view is under the page window that has the keys. The answer must be the view of the
/// pane that stays: the closed pane has no keyboard, no tab and no later use for a key.
///
/// Row 1: the hold's record at its opening. Row 2: the replay of a held key. Row 3: each view's own judge of a key
/// that it sees in a page window (the key monitor asks each view). Row 4 has no pane that leaves: a replayed key
/// passes the page window of a chat that waits drawn (`AgentPageDrawnParking`), which the app tells Chromium to show.
///
/// The model: each pane's host is a `PaneHost` (the layout's host view says the same thing through `PaneLeaving`),
/// each page is a fake Chromium page, and each page's window is a `PageWindow`. The rows set the leaving state by
/// hand: no close and no move run here. The hold's own opening (`begin`) is not run: it takes the key window of the
/// app, and a test process has none.
@MainActor @Suite(.serialized, .closesItsWindows)
struct NewTabHoldInAClosingPaneTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A model of a pane's host in a layout: it says whether its pane left the layout.
    private final class PaneHost: NSView, PaneLeaving {
        var isLeaving = false
    }

    /// Stands for a page's window of Chromium: a child window of the app's window. It counts the events that it gets,
    /// and it says that it is visible from the setup's end, so the rows need no display.
    private final class PageWindow: NSWindow {
        var got = 0
        var saysVisible = false
        override var isVisible: Bool { saysVisible || super.isVisible }
        override func sendEvent(_ event: NSEvent) { got += 1 }
    }

    /// One window with 2 panes at one place: the pane that stays, and above it the pane that leaves. Each has an
    /// agent pane view whose page is in Chromium, and a page window over the place; the window of the pane that
    /// stays is the first child window.
    @MainActor
    private struct Scene {
        let window: NSWindow
        let stays: AgentPaneView, leaves: AgentPaneView
        let staysPage: FakeChromiumPage, leavesPage: FakeChromiumPage
        let staysWindow: PageWindow, leavesWindow: PageWindow
        let folder: URL

        func close() {
            stays.page?.close()
            leaves.page?.close()
            for page in [staysWindow, leavesWindow] {
                page.saysVisible = false
                window.removeChildWindow(page)
                page.close()
            }
            window.close()
            try? FileManager.default.removeItem(at: folder)
        }

        /// The view that the lookup answers for `page`, in words.
        func answer(for page: NSWindow) -> String { name(AgentPaneView.chromiumAgentPane(under: page, in: window)) }

        func name(_ view: NSView?) -> String {
            guard let view else { return "no view" }
            if view === stays { return "the view of the pane that stays" }
            return view === leaves ? "the view of the pane that leaves" : "another view"
        }

        /// What the key left in each view: the host's touch mark and the gesture record.
        var marks: String {
            "the pane that stays: mark \(stays.model.hostTouch.marked), gesture \(stays.model.transport.gestures.isAvailable); "
                + "the pane that leaves: mark \(leaves.model.hostTouch.marked), gesture \(leaves.model.transport.gestures.isAvailable)"
        }
    }

    private static func paneWithAChromiumPage(from file: URL) async throws -> (AgentPaneView, FakeChromiumPage) {
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: true, testRoot: true, chromium: hosting))
        let page = try #require(view.page)
        await page.chromiumStart?.value
        let chromium = try #require(hosting.made.first, "setup: the view made no Chromium page")
        view.loadingView.leave(over: view.pageContent, fades: false)
        return (view, chromium)
    }

    private static func scene(leaving: Bool = true) async throws -> Scene {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: "hold-closing-pane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "index.html")
        try Data("<html><body><textarea></textarea></body></html>".utf8).write(to: file)
        let stays = try await paneWithAChromiumPage(from: file)
        let leaves = try await paneWithAChromiumPage(from: file)
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let staysHost = PaneHost(frame: content.bounds), leavesHost = PaneHost(frame: content.bounds)
        for (host, pane) in [(staysHost, stays.0), (leavesHost, leaves.0)] {
            host.autoresizingMask = [.width, .height]
            pane.frame = host.bounds
            pane.autoresizingMask = [.width, .height]
            host.addSubview(pane)
            content.addSubview(host)
        }
        content.layoutSubtreeIfNeeded()
        let place = window.convertToScreen(content.convert(content.bounds, to: nil))
        let windows = (0..<2).map { _ in PageWindow(contentRect: place, styleMask: [.borderless], backing: .buffered, defer: true) }
        for page in windows {
            page.isReleasedWhenClosed = false
            window.addChildWindow(page, ordered: .above)
            page.saysVisible = true
        }
        let scene = Scene(window: window, stays: stays.0, leaves: leaves.0, staysPage: stays.1, leavesPage: leaves.1,
                          staysWindow: windows[0], leavesWindow: windows[1], folder: folder)
        try #require(window.childWindows?.first === scene.staysWindow && scene.leavesWindow.parent === window,
                     "setup: the 2 page windows are not the window's child windows, the one of the pane that stays first")
        try #require(scene.staysPage.visibility.last == true && scene.leavesPage.visibility.last == true,
                     "setup: the app did not tell Chromium that each of the 2 pages shows")
        window.makeFirstResponder(nil)
        try #require(window.firstResponder === window, "setup: a view of the window has the keyboard")
        leavesHost.isLeaving = leaving
        return scene
    }

    /// The letter `a` as the keyboard sends it (the events of the HID system have the source process 0).
    private static func letter() throws -> NSEvent {
        let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    /// The hold's record at its opening, made as `NewTabInputCoordinator.begin` makes it: the keys are in the page
    /// window of the pane that stays, and the hold asks the lookup for the view under it. Then the New Tab page takes
    /// that pane's view, so the keys are the new page's: at an end with no ready field the hold drops none of them.
    /// The control is a hold whose view no new page took: it drops the key.
    @Test func theHoldKeepsTheViewOfThePaneThatStays() async throws {
        let scene = try await Self.scene()
        defer { scene.close() }
        let window = scene.window
        let answer = scene.answer(for: scene.staysWindow)
        func hold() -> NewTabHoldKeyboard {
            NewTabHoldKeyboard(in: window, keyWindow: scene.staysWindow, drawn: { AgentPaneView.chromiumAgentPane(under: $0, in: window) })
        }
        let taken = hold(), notTaken = hold()
        taken.newTabTook(scene.stays)
        taken.endedUnready = true
        notTaken.endedUnready = true
        let control = notTaken.drops(keyFor: scene.staysWindow), dropped = taken.drops(keyFor: scene.staysWindow)
        print("NewTabHoldInAClosingPaneTests: row 1, the hold's record: the lookup answered \(answer), want the view of the pane that stays; "
            + "after the new page took that view the hold dropped the key: \(dropped), want false; the control (no new page took the view) dropped it: \(control), want true")
        try #require(control, "setup: a hold whose view no new page took did not drop the key of its page window")
        #expect(!dropped, "the hold dropped a key of the page that the new tab took: its record has \(answer)")
    }

    /// The replay of a held letter, through the true `NewTabInputCoordinator.replay`. The app has no key window in a
    /// test process, so the replay takes the first child window over a shown agent page: the page window of the pane
    /// that stays. Want: that window gets the letter once, and the letter's touch mark and gesture record are in the
    /// view of the pane that stays, not in the view of the pane that leaves.
    @Test func aReplayedLetterIsJudgedInThePaneThatStays() async throws {
        let scene = try await Self.scene()
        defer { scene.close() }
        // The router holds its registry unowned: the test keeps it alive to its end.
        let registry = ActionRegistry.standard()
        defer { withExtendedLifetime(registry) {} }
        let router = KeyRouter(registry: registry)
        let letter = try Self.letter()
        NewTabInputCoordinator.replay(letter, held: letter, in: scene.window, router: router)
        print("NewTabHoldInAClosingPaneTests: row 2, a replayed letter: \(scene.marks); the page window of the pane that stays got "
            + "\(scene.staysWindow.got) event(s), want 1; the page window of the pane that leaves got \(scene.leavesWindow.got), want 0")
        try #require(scene.staysWindow.got == 1, "setup: the replay did not send the letter to the page window of the pane that stays")
        #expect(scene.leavesWindow.got == 0, "the page window of the pane that leaves got a held key")
        #expect(scene.stays.model.hostTouch.marked && scene.stays.model.transport.gestures.isAvailable,
                "the view of the pane that stays has no mark or no gesture of the replayed letter: \(scene.marks)")
        #expect(!scene.leaves.model.hostTouch.marked && !scene.leaves.model.transport.gestures.isAvailable,
                "the view of the pane that leaves took the replayed letter's mark or gesture: \(scene.marks)")
    }

    /// A key in the page window of the pane that stays, as the key monitor gives it to each agent pane view of the
    /// window. Each view judges it by its own place. Want: the view of the pane that leaves takes no mark and no
    /// gesture, and the view of the pane that stays takes both.
    @Test func aViewInAPaneThatLeavesJudgesNoKeyOfAPageWindow() async throws {
        let scene = try await Self.scene()
        defer { scene.close() }
        let letter = try Self.letter()
        scene.leaves.judge(letter, eventWindow: scene.staysWindow)
        scene.stays.judge(letter, eventWindow: scene.staysWindow)
        print("NewTabHoldInAClosingPaneTests: row 3, each view's judge of a key in the page window of the pane that stays: \(scene.marks)")
        #expect(!scene.leaves.model.hostTouch.marked && !scene.leaves.model.transport.gestures.isAvailable,
                "the view of the pane that leaves took the mark or the gesture of a key that is for the pane over it: \(scene.marks)")
        #expect(scene.stays.model.hostTouch.marked && scene.stays.model.transport.gestures.isAvailable,
                "the view of the pane that stays has no mark or no gesture of the key in its page window: \(scene.marks)")
    }

    /// The replay of a held letter while a chat waits drawn. The person left that chat by a tab switch: its view waits
    /// far outside the window's content, the app still tells Chromium that its page shows, and its page window is
    /// visible there. No pane leaves in this row. The chat's page window is the first child window, and the lookup
    /// finds the chat's view under it, so a replay that asks only for a view under a page window sends the letter to
    /// the chat that the person left. Want: that window gets no event, the page window of the pane that shows its
    /// page gets the letter once, and the chat's view takes no mark and no gesture.
    @Test func aReplayedLetterPassesAChatThatWaitsDrawn() async throws {
        let scene = try await Self.scene(leaving: false)
        defer { scene.close() }
        let chat = scene.stays, chatWindow = scene.staysWindow, shown = scene.leaves, shownWindow = scene.leavesWindow
        chat.model.markPainted()
        try #require(AgentPageDrawnParking.park(chat), "setup: the chat does not wait drawn")
        let content = scene.staysPage.contentView
        let place = try #require(content.window.map { $0.convertToScreen(content.convert(content.bounds, to: nil)) },
                                 "setup: the page of the chat that waits drawn is in no window")
        chatWindow.setFrame(place, display: false)
        try #require(chat.page?.isDrawnAway == true && chat.page?.chromiumShows == true && chatWindow.isVisible,
                     "setup: the chat is not drawn away, or the app told Chromium that its page is hidden")
        try #require(AgentPaneView.chromiumAgentPane(under: chatWindow, in: scene.window) === chat,
                     "setup: the lookup does not find the chat's view under the chat's page window")
        try #require(AgentPaneView.chromiumAgentPane(under: shownWindow, in: scene.window) === shown,
                     "setup: the lookup does not find the shown view under its page window")
        // The router holds its registry unowned: the test keeps it alive to its end.
        let registry = ActionRegistry.standard()
        defer { withExtendedLifetime(registry) {} }
        let router = KeyRouter(registry: registry)
        let letter = try Self.letter()
        NewTabInputCoordinator.replay(letter, held: letter, in: scene.window, router: router)
        let marks = "the chat that waits drawn: mark \(chat.model.hostTouch.marked), gesture \(chat.model.transport.gestures.isAvailable); "
            + "the shown view: mark \(shown.model.hostTouch.marked), gesture \(shown.model.transport.gestures.isAvailable)"
        print("NewTabHoldInAClosingPaneTests: row 4, a replayed letter with a chat that waits drawn: the chat's page window got "
            + "\(chatWindow.got) event(s), want 0; the page window of the shown view got \(shownWindow.got), want 1; \(marks)")
        #expect(chatWindow.got == 0, "the page window of a chat that waits drawn got a held key")
        #expect(shownWindow.got == 1, "the page window of the shown view did not get the held key once: \(shownWindow.got)")
        #expect(!chat.model.hostTouch.marked && !chat.model.transport.gestures.isAvailable,
                "the chat that waits drawn took the replayed letter's mark or gesture: \(marks)")
        #expect(shown.model.hostTouch.marked && shown.model.transport.gestures.isAvailable,
                "the shown view has no mark or no gesture of the replayed letter: \(marks)")
    }
}
#endif
