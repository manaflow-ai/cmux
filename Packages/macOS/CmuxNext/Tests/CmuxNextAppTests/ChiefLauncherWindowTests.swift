import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// The floating Chief is a Raycast-style window of its own (user 2026-11-09: "cmd i feature is very bad i can't drag
/// the window around", then "it should be raycast-type floating window"): Cmd-I and Option-Shift-Space open a
/// borderless panel over every app and Space, at once and with the message box focused; a press on any empty space
/// drags it (the panel inside the window moved only by an 18 pt strip, and only inside the window); it comes back
/// where it was left; Esc or a click outside hides it and gives the Chief back to Home. Mouse events go through the
/// panel's `sendEvent`, as a person's do.
@MainActor @Suite(.serialized, .closesItsWindows)
struct ChiefLauncherWindowTests {
    typealias Fixture = SidebarMultiViewWindowTests.Fixture

    /// The Chief stand-in: empty space around a message box (a text view that takes the keys), a view that keeps its
    /// presses (it handles them itself, as a send button does, and says nothing of the window), and a transcript (one
    /// view: its top half a message whose text selects, its bottom half empty space between messages).
    final class Chief: NSView {
        let draft = NSTextView(frame: NSRect(x: 8, y: 8, width: 220, height: 40))
        let keeper = Keeper(frame: NSRect(x: 8, y: 300, width: 120, height: 40))
        let transcript = Transcript(frame: NSRect(x: 160, y: 60, width: 150, height: 200))
        init() {
            super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
            addSubview(draft)
            addSubview(keeper)
            addSubview(transcript)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }
    }

    final class Keeper: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private(set) var presses = 0
        override func mouseDown(with event: NSEvent) { presses += 1 }
    }

    /// A transcript stand-in: it takes every press (selection) and says which are on empty space.
    final class Transcript: NSView, WindowBackgroundDragDeciding {
        override var isFlipped: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private(set) var selects = 0
        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) { selects += 1 }
        func pressMovesWindow(atWindowPoint point: CGPoint, hit: NSView) -> Bool? {
            guard hit === self else { return nil }
            return convert(point, from: nil).y < bounds.midY // the bottom half: empty space
        }
    }

    /// A window showing `k1` (Home is `k0`), the actions bound, the Chief closed; its frames saved in a scratch domain.
    static func open() async throws -> (Fixture, Chief) {
        let chief = Chief()
        let f = try await ChiefPanelWindowTests.fixture(chief)
        UserDefaults.standard.removeObject(forKey: ChiefLauncherPanel.framesKey)
        AppActions.bind(f.services)
        f.services.windows.show(workspaceID: "k1", in: f.state, from: .thisWindow)
        f.frame()
        try #require(!f.controller.frameChiefPanelShown)
        return (f, chief)
    }

    static func perform(_ id: ActionID, _ f: Fixture) -> Bool {
        let done = f.services.registry.perform(id, invocation: ActionInvocation(origin: .user))
        f.frame()
        return done
    }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Presses `view` at `point` (its coordinates) and moves the hand by `delta` (screen points, y up), as a hand does:
    /// each event's place is where the hand is over the window as it is then.
    static func drag(at point: NSPoint, in view: NSView, by delta: CGVector, flags: NSEvent.ModifierFlags = []) throws {
        let window = try #require(view.window)
        let start = window.convertPoint(toScreen: view.convert(point, to: nil))
        window.sendEvent(mouse(.leftMouseDown, at: window.convertPoint(fromScreen: start), in: window, flags: flags))
        for step in 1...4 {
            let t = CGFloat(step) / 4
            let hand = NSPoint(x: start.x + delta.dx * t, y: start.y + delta.dy * t)
            window.sendEvent(mouse(.leftMouseDragged, at: window.convertPoint(fromScreen: hand), in: window, flags: flags))
        }
        let end = NSPoint(x: start.x + delta.dx, y: start.y + delta.dy)
        window.sendEvent(mouse(.leftMouseUp, at: window.convertPoint(fromScreen: end), in: window, flags: flags))
    }

    /// Cmd-I opens the Chief in its own window: borderless, floating over every app and Space, never activating
    /// cmux, with no opening motion; the Chief's own view is in it with the keys in its message box. Cmd-I again
    /// hides it and Home's pane has the Chief back.
    @Test func cmdIOpensTheChiefInItsOwnFloatingWindow() async throws {
        let (f, chief) = try await Self.open()
        defer { f.close() }
        #expect(Self.perform("home.openChiefDock", f))
        let view = try #require(f.controller.chiefPanelView)
        let launcher = try #require(view.launcher)
        #expect(view.window === launcher && chief.window === launcher, "the Chief is not in its own window: \(String(describing: chief.window))")
        #expect(launcher !== f.controller.window && launcher.isVisible, "the launcher does not show")
        #expect(!launcher.styleMask.contains(.titled) && launcher.styleMask.contains(.nonactivatingPanel), "not a borderless nonactivating panel: \(launcher.styleMask)")
        #expect(launcher.isFloatingPanel && launcher.level.rawValue >= NSWindow.Level.floating.rawValue, "it does not float over other apps")
        #expect(launcher.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]), "it does not follow to every Space")
        #expect(!launcher.hidesOnDeactivate && launcher.animationBehavior == .none, "it hides with cmux or animates its opening")
        #expect(launcher.firstResponder === chief.draft, "the message box does not have the keys: \(String(describing: launcher.firstResponder))")
        #expect(f.controller.frameChiefPanelShown && f.controller.frameChiefPanelHasKeys)
        #expect(Self.perform("home.openChiefDock", f))
        #expect(!launcher.isVisible && !f.controller.frameChiefPanelShown, "Cmd-I did not hide it")
        #expect(chief.window !== launcher, "the Chief did not go back to Home's pane")
    }

    /// Option-Shift-Space opens and hides the same window from any app.
    @Test func theGlobalKeyOpensAndHidesTheSameWindow() async throws {
        let (f, chief) = try await Self.open()
        defer { f.close() }
        #expect(Self.perform("home.showHideChiefFromAnyApp", f))
        let launcher = try #require(f.controller.chiefPanelView?.launcher)
        #expect(launcher.isVisible && chief.window === launcher && launcher.firstResponder === chief.draft)
        #expect(Self.perform("home.showHideChiefFromAnyApp", f))
        #expect(!launcher.isVisible, "the global key did not hide it")
    }

    /// The first open sits centered, its top a sixth of the way down the screen under the pointer; a drag from any
    /// empty space moves it (the window, past the cmux window's edge too), and it reopens where it was left.
    @Test func itOpensHighAndCenteredThenDragsAnywhereAndComesBackThere() async throws {
        let (f, chief) = try await Self.open()
        defer { f.close() }
        #expect(Self.perform("home.openChiefDock", f))
        let launcher = try #require(f.controller.chiefPanelView?.launcher)
        let visible = try #require(launcher.screen?.visibleFrame)
        #expect(launcher.frame == ChiefLauncherPanel.placement(saved: nil, in: visible), "first open at \(launcher.frame)")
        #expect(abs(launcher.frame.midX - visible.midX) <= 1, "not centered: \(launcher.frame) on \(visible)")
        #expect(launcher.frame.maxY > visible.midY, "not in the upper part of the screen: \(launcher.frame)")
        let start = launcher.frame
        try Self.drag(at: NSPoint(x: 260, y: 330), in: chief, by: CGVector(dx: -300, dy: -80))
        #expect(abs(launcher.frame.minX - (start.minX - 300)) <= 1 && abs(launcher.frame.minY - (start.minY - 80)) <= 1,
                "a drag on empty space did not move it: \(start) -> \(launcher.frame)")
        let left = launcher.frame
        #expect(Self.perform("home.openChiefDock", f) && !launcher.isVisible)
        #expect(Self.perform("home.openChiefDock", f))
        #expect(launcher.frame == left, "it did not come back where it was left: \(left) -> \(launcher.frame)")
    }

    /// A press the Chief's own views keep (a button, a bubble, the message box) stays theirs, and a click on empty
    /// space is a click: neither moves the window. Cmd-drag moves it from anywhere.
    @Test func aPressTheChiefKeepsDoesNotMoveItButCmdDragDoes() async throws {
        let (f, chief) = try await Self.open()
        defer { f.close() }
        #expect(Self.perform("home.openChiefDock", f))
        let launcher = try #require(f.controller.chiefPanelView?.launcher)
        let start = launcher.frame
        try Self.drag(at: NSPoint(x: 60, y: 320), in: chief, by: CGVector(dx: 120, dy: 40))
        #expect(launcher.frame == start, "a press on a view that keeps it moved the window: \(launcher.frame)")
        #expect(chief.keeper.presses == 1, "the view did not get its press")
        try Self.drag(at: NSPoint(x: 260, y: 330), in: chief, by: CGVector(dx: 1, dy: 1))
        #expect(launcher.frame == start, "a click on empty space moved the window")
        try Self.drag(at: NSPoint(x: 60, y: 320), in: chief, by: CGVector(dx: 120, dy: 40), flags: .command)
        #expect(abs(launcher.frame.minX - (start.minX + 120)) <= 1, "Cmd-drag did not move it: \(launcher.frame)")
    }

    /// A transcript (one view) moves the window from its empty space and keeps a press on a message for its selection.
    @Test func theTranscriptSaysWhereItsEmptySpaceIs() async throws {
        let (f, chief) = try await Self.open()
        defer { f.close() }
        #expect(Self.perform("home.openChiefDock", f))
        let launcher = try #require(f.controller.chiefPanelView?.launcher)
        let start = launcher.frame
        try Self.drag(at: NSPoint(x: 75, y: 150), in: chief.transcript, by: CGVector(dx: 60, dy: 0)) // a message
        #expect(launcher.frame == start, "a drag on a message moved the window: \(launcher.frame)")
        #expect(chief.transcript.selects > 0, "the message's text did not get the drag")
        try Self.drag(at: NSPoint(x: 75, y: 40), in: chief.transcript, by: CGVector(dx: 60, dy: 0)) // empty space
        #expect(abs(launcher.frame.minX - (start.minX + 60)) <= 1, "a drag on the transcript's empty space did not move it: \(launcher.frame)")
    }

    /// The Chief's own popups (its settings card, a menu or picker: a child panel that takes the keys) and sheets are
    /// not a click outside: the window stays, and gets the keys back when the popup closes.
    @Test func itsOwnPopupsAndSheetsDoNotHideIt() async throws {
        let (f, chief) = try await Self.open()
        defer { f.close() }
        #expect(Self.perform("home.openChiefDock", f))
        let launcher = try #require(f.controller.chiefPanelView?.launcher)
        try #require(launcher.isKeyWindow || launcher.firstResponder === chief.draft)
        let popup = NativePopupHost(panel: NativePopupPanel(identifier: "test.chiefLauncher.popup"))
        let anchor = launcher.convertToScreen(chief.convert(chief.keeper.frame, to: nil))
        _ = popup.show(size: CGSize(width: 200, height: 120), anchor: anchor, in: launcher, makeKey: true)
        f.frame()
        #expect(popup.isShown, "the popup did not show")
        #expect(launcher.isVisible && f.controller.frameChiefPanelShown, "the Chief's own popup hid it")
        popup.hide()
        f.frame()
        #expect(launcher.isVisible, "closing the popup hid it")
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        launcher.beginSheet(sheet, completionHandler: nil)
        f.frame()
        #expect(launcher.isVisible && f.controller.frameChiefPanelShown, "a sheet on it hid it")
        launcher.endSheet(sheet)
        sheet.close()
        f.frame()
        #expect(launcher.isVisible, "closing the sheet hid it")
    }

    /// Esc hides it, and so does a click outside (it gives up the keys), each giving the Chief back to Home.
    @Test func escAndAClickOutsideHideIt() async throws {
        let (f, chief) = try await Self.open()
        defer { f.close() }
        #expect(Self.perform("home.openChiefDock", f))
        let view = try #require(f.controller.chiefPanelView)
        let launcher = try #require(view.launcher)
        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: launcher.windowNumber, context: nil, characters: "\u{1b}",
                                                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(view.performKeyEquivalent(with: esc), "Esc did not reach the Chief")
        f.frame()
        #expect(!launcher.isVisible && !f.controller.frameChiefPanelShown && chief.window !== launcher, "Esc did not hide it")
        #expect(Self.perform("home.openChiefDock", f) && launcher.isVisible)
        launcher.resignKey() // a click in another app or window
        f.frame()
        #expect(!launcher.isVisible && !f.controller.frameChiefPanelShown && chief.window !== launcher, "a click outside did not hide it")
    }

    /// A link clicked in the Chief on Home opens its workspace with the Chief floating in its window, without the
    /// keys (the workspace has them), so it does not hide until it had them.
    @Test func aLinkOpensItFloatingWithoutTheKeys() async throws {
        let chief = Chief()
        let f = try await ChiefPanelWindowTests.fixture(chief)
        defer { f.close() }
        f.controller.armChiefPanel()
        f.services.windows.show(workspaceID: "k1", in: f.state)
        f.frame()
        let launcher = try #require(f.controller.chiefPanelView?.launcher)
        #expect(launcher.isVisible && chief.window === launcher, "the link did not float the Chief in its window")
        #expect(!f.controller.frameChiefPanelHasKeys)
    }

    /// Docked, the Chief stays a pane inside the window, never in the floating one.
    @Test func dockedItStaysInTheWindow() async throws {
        let (f, chief) = try await Self.open()
        defer { f.close() }
        f.controller.dockChiefPanel(at: .left)
        f.frame()
        let view = try #require(f.controller.chiefPanelView)
        #expect(view.window === f.controller.window && chief.window === f.controller.window, "docked, it left the window")
        #expect(view.launcher?.isVisible != true, "docked, the floating window shows")
        #expect(f.controller.floatChiefPanel())
        f.frame()
        #expect(view.launcher?.isVisible == true && chief.window === view.launcher, "floated again, it is not in its own window")
    }
}
