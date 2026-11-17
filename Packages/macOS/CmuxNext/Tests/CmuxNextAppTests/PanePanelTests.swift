import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The window of a floating pane (`PanePanel`): it can have the keys and is never the main window, its bar moves
/// it with no rule of its own, and the keys in it are the keys of its parent window's content.
///
/// No test here needs a display: each reads the panel's own answers. What a real screen does with the panel (its
/// order above the parent, a real press on its bar) is not read here.
@MainActor @Suite(.serialized, .closesItsWindows) struct PanePanelTests {
    /// A parent window that answers a key equivalent as the test says and counts each ask.
    @MainActor final class Parent: NSWindow {
        var takes = false
        var asked = 0
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            asked += 1
            return takes
        }
    }

    /// A window delegate that writes down each key change that it hears.
    @MainActor final class KeyRecorder: NSObject, NSWindowDelegate {
        var changes: [Bool] = []
        func windowDidBecomeKey(_ notification: Notification) { changes.append(true) }
        func windowDidResignKey(_ notification: Notification) { changes.append(false) }
    }

    static let frame = NSRect(x: 300, y: 300, width: 300, height: 200)

    static func parent() -> Parent {
        let window = Parent(contentRect: NSRect(x: 200, y: 200, width: 800, height: 600), styleMask: [.titled], backing: .buffered,
                            defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aPanelCanHaveTheKeysAndIsNeverTheMainWindow() {
        let panel = PanePanel(pane: "p1", frame: Self.frame)
        defer { panel.closeAfterTest() }
        #expect(panel.pane == "p1")
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain, "a floating pane's panel took the main look from its app window")
        #expect(panel.level == .normal && !panel.isFloatingPanel, "a floating pane's panel is above the windows of other apps")
        #expect(!panel.hidesOnDeactivate, "a floating pane's panel goes when the app is not active")
        #expect(!panel.isMovable, "AppKit moves the panel by itself: only the bar, a size change and the owner set its frame")
        #expect(panel.collectionBehavior.contains(.ignoresCycle), "the window cycle key stops at a floating pane's panel")
    }

    @Test func theBarIsTheTopBandInsideTheEdgesThatChangeTheSize() {
        let panel = PanePanel(pane: "p1", frame: Self.frame)
        defer { panel.closeAfterTest() }
        let size = panel.frame.size
        #expect(!panel.isInBar(NSPoint(x: size.width / 2, y: size.height - 8)), "a panel with no bar height has a bar")
        panel.barHeight = 14
        #expect(panel.isInBar(NSPoint(x: size.width / 2, y: size.height - 8)))
        #expect(!panel.isInBar(NSPoint(x: size.width / 2, y: size.height - 20)), "the pane's content under the bar moves the panel")
        #expect(!panel.isInBar(NSPoint(x: size.width / 2, y: size.height - 2)), "the top edge is the size change's, not the bar's")
        #expect(!panel.isInBar(NSPoint(x: 2, y: size.height - 8)), "the left edge is the size change's, not the bar's")
        #expect(!panel.isInBar(NSPoint(x: size.width - 2, y: size.height - 8)), "the right edge is the size change's, not the bar's")
    }

    @Test func aMoveByTheBarFollowsThePointerWithNoOtherRule() {
        let origin = PanePanel.origin(movedFrom: NSPoint(x: 100, y: 100), pointerFrom: NSPoint(x: 10, y: 10), to: NSPoint(x: -500, y: 2000))
        #expect(origin == NSPoint(x: -410, y: 2090), "the move held the panel inside a display or its window")
    }

    @Test func thePanelKeepsTheFrameThatItsOwnerGivesIt() {
        let panel = PanePanel(pane: "p1", frame: Self.frame)
        defer { panel.closeAfterTest() }
        let far = NSRect(x: -5000, y: 9000, width: 300, height: 200)
        #expect(panel.constrainFrameRect(far, to: NSScreen.main) == far, "AppKit moves a panel back onto a display: the plan gives the frame")
    }

    @Test func aKeyChangeOfAPanelIsAKeyChangeForItsParentsDelegate() {
        let parent = Self.parent(), recorder = KeyRecorder()
        parent.delegate = recorder
        let panel = PanePanel(pane: "p1", frame: Self.frame)
        defer {
            parent.removeChildWindow(panel)
            panel.closeAfterTest()
            parent.closeAfterTest()
        }
        panel.becomeKey()
        #expect(recorder.changes.isEmpty, "a panel with no parent told a window that it has the keys")
        panel.resignKey()
        parent.addChildWindow(panel, ordered: .above)
        panel.becomeKey()
        #expect(recorder.changes == [true], "the parent's delegate did not hear that its window's content has the keys")
        panel.resignKey()
        #expect(recorder.changes == [true, false], "the parent's delegate did not hear that its window's content lost the keys")
    }

    @Test func aKeyEquivalentInAPanelGoesToTheParentFirst() throws {
        let parent = Self.parent()
        let panel = PanePanel(pane: "p1", frame: Self.frame)
        defer {
            parent.removeChildWindow(panel)
            panel.closeAfterTest()
            parent.closeAfterTest()
        }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil, characters: "k",
                                                  charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        #expect(!panel.performKeyEquivalent(with: event))
        #expect(parent.asked == 0, "a panel with no parent asked a window")
        parent.addChildWindow(panel, ordered: .above)
        #expect(!panel.performKeyEquivalent(with: event), "a key that nothing takes was taken")
        #expect(parent.asked == 1, "the parent was not asked for a key typed in its panel")
        parent.takes = true
        #expect(panel.performKeyEquivalent(with: event), "the parent took the key and the panel said that nothing did")
        #expect(parent.asked == 2)
    }

    /// A floating pane's panel is content of the app window that it is a child of, and so is a page window in it.
    /// A plain panel over the app window, and a page window in it, gate the menu chords as before.
    @Test func aFloatingPanesPanelIsContentOfItsAppWindowAndAPlainPanelIsNot() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["pane-panel-kind"]))
        let window = try #require(controller.window)
        let panel = PanePanel(pane: "p1", frame: Self.frame)
        let plain = NSPanel(contentRect: Self.frame, styleMask: [.titled], backing: .buffered, defer: true)
        let pages = [panel, plain].map { _ in NSWindow(contentRect: Self.frame, styleMask: [.borderless], backing: .buffered, defer: true) }
        defer {
            for (page, owner) in zip(pages, [panel, plain]) {
                owner.removeChildWindow(page)
                page.closeAfterTest()
            }
            for child in [panel, plain] {
                window.removeChildWindow(child)
                child.closeAfterTest()
            }
            window.close()
            AppHarnessWindows.closeThoseThisTestOpened()
        }
        window.addChildWindow(panel, ordered: .above)
        window.addChildWindow(plain, ordered: .above)
        panel.addChildWindow(pages[0], ordered: .above)
        plain.addChildWindow(pages[1], ordered: .above)
        let router = services.keyRouter
        #expect(router.focus(for: window).1 == .content)
        #expect(router.focus(for: panel).0 === controller, "a floating pane's panel belongs to no app window")
        #expect(router.focus(for: panel).1 == .content, "a floating pane's panel gates the menu chords like a panel over the window")
        #expect(router.focus(for: pages[0]).0 === controller)
        #expect(router.focus(for: pages[0]).1 == .content, "a page window in a floating pane's panel is not content")
        #expect(router.focus(for: plain).0 === controller)
        #expect(router.focus(for: plain).1 == .textPanel, "a plain panel over the window became content")
        #expect(router.focus(for: pages[1]).1 == .textPanel, "a page window in a plain panel became content")
    }
}
