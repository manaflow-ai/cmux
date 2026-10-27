import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// Task p04-input-086 of plans/cmux-next/chrome-parity/p04-input.md: a chord the key router decided
/// reaches a focused terminal or page as a key equivalent with no walk over the window's other views,
/// as Chrome's `CommandDispatcher` gives it to a `CommandDispatcherTarget` first responder
/// (ui/base/cocoa/command_dispatcher.mm). Any other key or responder keeps AppKit's walk. The menu
/// search of a decided chord refuses its registry items before any availability check.
@MainActor @Suite(.serialized) struct KeyEquivalentWalkTests {
    /// A pane's view that counts the key equivalents the window offers it.
    final class PaneProbe: NSView {
        var offered = 0

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            offered += 1
            return false
        }
    }

    /// What a test counted: availability checks and menu gate questions.
    @MainActor final class Counts {
        var availability = 0
        var gate = 0
        var gateAllows = false
        var dispatching = true
        var ran = 0
    }

    /// A shell window of 30 panes beside the view that has the keyboard, and its key router.
    struct Shown {
        let window: ShellWindow
        let router: KeyRouter
        /// The router holds it `unowned`.
        let registry: ActionRegistry
        let panes: [PaneProbe]

        /// Key equivalents offered to the 30 panes.
        var offers: Int { panes.reduce(0) { $0 + $1.offered } }
    }

    static func shown(_ focused: NSView, responder: NSView, registry: ActionRegistry = .standard()) throws -> Shown {
        _ = NSApplication.shared
        let router = KeyRouter(registry: registry)
        let window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 960), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.keyRouter = router
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 960))
        let panes = (0 ..< 30).map { index in
            PaneProbe(frame: NSRect(x: CGFloat(index % 6) * 200, y: CGFloat(index / 6) * 160, width: 200, height: 160))
        }
        for pane in panes { root.addSubview(pane) }
        focused.frame = NSRect(x: 0, y: 800, width: 480, height: 160)
        root.addSubview(focused)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        // On screen, as AppKit offers key equivalents to a window the person sees.
        window.orderFrontRegardless()
        try #require(window.makeFirstResponder(responder), "the focused view never took the keyboard")
        return Shown(window: window, router: router, registry: registry, panes: panes)
    }

    static func terminal() throws -> (TerminalSession, ScriptedTerminalIO) {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        return (session, io)
    }

    private static var timestamp: TimeInterval = 8600

    static func key(_ characters: String, ignoringModifiers: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16,
                    in window: NSWindow) throws -> NSEvent {
        timestamp += 1
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                             windowNumber: window.windowNumber, context: nil, characters: characters,
                                             charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: keyCode))
    }

    static func controlC(in window: NSWindow) throws -> NSEvent {
        try key("\u{3}", ignoringModifiers: "c", [.control], keyCode: 8, in: window)
    }

    /// Ctrl-C the dispatcher decided for the focused terminal of a 30-pane window: only the terminal
    /// is asked (it leaves the key to its key-down pass, as before); no pane is offered the key.
    @Test func aDecidedChordReachesTheFocusedTerminalAlone() throws {
        let (session, io) = try Self.terminal()
        let shown = try Self.shown(session.view, responder: session.surfaceView)
        defer { io.finish(); shown.window.close() }
        let event = try Self.controlC(in: shown.window)
        shown.router.decided.add(event)
        #expect(shown.router.directKeyEquivalentTarget(for: event, firstResponder: shown.window.firstResponder) === session.surfaceView)

        #expect(!shown.window.performKeyEquivalent(with: event), "the terminal took Ctrl-C as a key equivalent")
        #expect(shown.offers == 0, "the window walked \(shown.offers) pane views for a chord its terminal has")
        #expect(session.surfaceView.lastPerformKeyEventTimestamp == event.timestamp, "the terminal was never offered Ctrl-C")
    }

    /// A chord the dispatcher never saw (a synthetic event) keeps AppKit's walk: every pane is offered it.
    @Test func anUndecidedChordStillWalksEveryView() throws {
        let (session, io) = try Self.terminal()
        let shown = try Self.shown(session.view, responder: session.surfaceView)
        defer { io.finish(); shown.window.close() }
        let event = try Self.controlC(in: shown.window)
        #expect(shown.router.directKeyEquivalentTarget(for: event, firstResponder: shown.window.firstResponder) == nil)

        _ = shown.window.performKeyEquivalent(with: event)
        #expect(shown.offers == 30, "an undecided chord was offered to \(shown.offers) of 30 pane views")
    }

    /// A text view's chord can belong to a view around it (a find bar's Cmd-G): it keeps the walk.
    @Test func aDecidedChordInATextViewKeepsTheWalk() throws {
        let text = NSTextView(frame: .zero)
        let shown = try Self.shown(text, responder: text)
        defer { shown.window.close() }
        let event = try Self.key("g", ignoringModifiers: "g", [.command], keyCode: 5, in: shown.window)
        shown.router.decided.add(event)
        #expect(shown.router.directKeyEquivalentTarget(for: event, firstResponder: shown.window.firstResponder) == nil)

        _ = shown.window.performKeyEquivalent(with: event)
        #expect(shown.offers == 30, "a text view's chord was offered to \(shown.offers) of 30 pane views")
    }

    /// During a key-down a registry menu item asks the menu gate first: a refusal (a chord the router
    /// decided) checks no availability; an allowed key equivalent and an open menu still check it.
    @Test func aRefusedKeyEquivalentChecksNoAvailability() throws {
        let registry = ActionRegistry.standard()
        let counts = Counts()
        registry.bind("newTab.default", isEnabled: { counts.availability += 1; return true }) {}
        registry.isDispatchingKeyDown = { counts.dispatching }
        registry.menuKeyEquivalentGate = { _ in
            counts.gate += 1
            return counts.gateAllows
        }
        let item = try #require(registry.makeMenuItem(for: "newTab.default"))
        try #require(item.keyEquivalent == "t", "New Tab is not on Cmd-T: \(item.keyEquivalent.debugDescription)")
        let validation = try #require(item.target as? any NSMenuItemValidation)

        #expect(!validation.validateMenuItem(item), "a refused key equivalent enabled its item")
        #expect(counts.gate == 1)
        #expect(counts.availability == 0, "a refused key equivalent checked its action's availability")

        counts.gateAllows = true
        #expect(validation.validateMenuItem(item))
        #expect(counts.gate == 2)
        #expect(counts.availability == 1)

        // An open menu (no key-down): the gate is not asked, and the item shows enabled.
        counts.dispatching = false
        counts.gateAllows = false
        #expect(validation.validateMenuItem(item), "New Tab shows disabled in the open menu")
        #expect(counts.gate == 2)
        #expect(counts.availability == 2)
    }

    /// Cmd-T the dispatcher decided and gave the focused terminal (it ran nothing for it): the window
    /// asks the terminal alone, the menu validates New Tab at most once, checks no availability, and
    /// never runs it.
    @Test func aDecidedCmdTValidatesTheMenuAtMostOnce() throws {
        let (session, io) = try Self.terminal()
        let registry = ActionRegistry.standard()
        let shown = try Self.shown(session.view, responder: session.surfaceView, registry: registry)
        let counts = Counts()
        registry.bind("newTab.default", isEnabled: { counts.availability += 1; return true }) { counts.ran += 1 }
        let router = shown.router
        registry.isDispatchingKeyDown = { router.inputDispatch.isKeyDown }
        registry.menuKeyEquivalentGate = { id in
            counts.gate += 1
            return router.allowsMenuKeyEquivalent(id)
        }
        let bar = NSMenu(), holder = NSMenuItem(title: "File", action: nil, keyEquivalent: ""), file = NSMenu(title: "File")
        let newTab = try #require(registry.makeMenuItem(for: "newTab.default"))
        file.addItem(newTab)
        holder.submenu = file
        bar.addItem(holder)
        let previousMenu = NSApp.mainMenu, previousClaim = TerminalKeyEquivalent.menuMayClaim
        NSApp.mainMenu = bar
        TerminalKeyEquivalent.menuMayClaim = { [weak router] in router?.menuMayClaim($0) ?? true }
        defer {
            NSApp.mainMenu = previousMenu
            TerminalKeyEquivalent.menuMayClaim = previousClaim
            io.finish()
            shown.window.close()
        }
        let event = try Self.key("t", ignoringModifiers: "t", [.command], keyCode: 17, in: shown.window)
        router.decided.add(event)

        _ = router.dispatchingSynthetic(event) { shown.window.performKeyEquivalent(with: event) }
        #expect(shown.offers == 0, "the window walked \(shown.offers) pane views for the terminal's Cmd-T")
        #expect(counts.gate <= 1, "the menu validated New Tab \(counts.gate) times for one Cmd-T")
        #expect(counts.availability == 0, "a refused Cmd-T checked New Tab's availability")
        #expect(counts.ran == 0, "the menu ran New Tab for a Cmd-T the router gave the terminal")
    }
}
