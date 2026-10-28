import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextRemoteBrowser
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// Task p04-input-086 of plans/cmux-next/chrome-parity/p04-input.md: a chord the key router decided
/// reaches a focused terminal or page as a key equivalent with no walk over the window's other views,
/// as Chrome's `CommandDispatcher` gives it to a `CommandDispatcherTarget` first responder
/// (ui/base/cocoa/command_dispatcher.mm); a field editor's chord walks its own pane only. Any other key
/// or responder keeps AppKit's walk. The main menu (`ActionMenuBar`) is not searched for a decided chord
/// whose only items the menu gate refuses, in the terminal's menu-first pass or `NSApplication`'s.
@MainActor @Suite(.serialized) struct KeyEquivalentWalkTests {
    /// A pane's view that counts the key equivalents the window offers it.
    final class PaneProbe: NSView {
        var offered = 0

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            offered += 1
            return false
        }
    }

    /// A find bar: takes Cmd-G while its field edits, as `TerminalFindBarView` does.
    final class FindBarProbe: NSView {
        let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 200, height: 24))
        var took = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(field)
        }

        required init?(coder: NSCoder) { nil }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.charactersIgnoringModifiers == "g", let editor = window?.firstResponder as? NSView,
                  editor.isDescendant(of: self) else { return super.performKeyEquivalent(with: event) }
            took += 1
            return true
        }
    }

    /// What a test counted: availability checks and menu gate questions.
    @MainActor final class Counts {
        var availability = 0
        var gate = 0
        var gateAllows = false
        var dispatching = true
        var ran = 0
        /// The key-down being dispatched (`ActionRegistry.dispatchingInputEvent`).
        var event: NSEvent?
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

    /// `install` runs once `focused` is in the window, before `responder` takes the keyboard.
    static func shown(_ focused: NSView, responder: NSView, registry: ActionRegistry = .standard(),
                      install: () -> Void = {}) throws -> Shown {
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
        install()
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
                    in window: NSWindow?) throws -> NSEvent {
        timestamp += 1
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                             windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                             charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: keyCode))
    }

    static func controlC(in window: NSWindow) throws -> NSEvent {
        try key("\u{3}", ignoringModifiers: "c", [.control], keyCode: 8, in: window)
    }

    /// A main menu bar holding `items` in one submenu; `decided` is the router's set of decided keys.
    static func bar(_ registry: ActionRegistry, _ items: [NSMenuItem], decided: DecidedKeyEvents) -> ActionMenuBar {
        let bar = ActionMenuBar(registry: registry, decidedKey: { decided.contains($0) })
        let holder = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let file = NSMenu(title: "File")
        for item in items { file.addItem(item) }
        holder.submenu = file
        bar.addItem(holder)
        return bar
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
        let before = shown.router.decided.offers

        #expect(!shown.window.performKeyEquivalent(with: event), "the terminal took Ctrl-C as a key equivalent")
        #expect(shown.offers == 0, "the window walked \(shown.offers) pane views for a chord its terminal has")
        #expect(session.surfaceView.lastPerformKeyEventTimestamp == event.timestamp, "the terminal was never offered Ctrl-C")
        let offers = shown.router.decided.offers
        #expect(offers.focusedSurface - before.focusedSurface == 1, "the debug counter missed the terminal's one offer")
        #expect(offers.windowWalks == before.windowWalks, "the debug counter saw a window walk")
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

    /// The surfaces that take their own key equivalents are named by ``KeyEquivalentOwningSurface``, not by
    /// type in the router, so a Release build (no remote browser page) compiles it (Mac build
    /// ba28759692eb7bd5c6f51408: "cannot find type 'RemoteBrowserContentView' in scope"). The Chromium host
    /// page and the remote browser page still own theirs; a pane view or a text view does not.
    @Test func thePageSurfacesOwnTheirKeyEquivalents() {
        #expect(KeyRouter.takesOwnKeyEquivalents(ChromiumHostPageView(frame: .zero)))
        #expect(KeyRouter.takesOwnKeyEquivalents(RemoteBrowserContentView(frame: .zero)))
        #expect(!KeyRouter.takesOwnKeyEquivalents(NSView(frame: .zero)))
        #expect(!KeyRouter.takesOwnKeyEquivalents(NSTextView(frame: .zero)))
    }

    /// A text view outside every pane (not a field editor) keeps the walk, and the counter names it.
    @Test func aDecidedChordInATextViewKeepsTheWalk() throws {
        let text = NSTextView(frame: .zero)
        let shown = try Self.shown(text, responder: text)
        defer { shown.window.close() }
        let event = try Self.key("g", ignoringModifiers: "g", [.command], keyCode: 5, in: shown.window)
        shown.router.decided.add(event)

        _ = shown.window.performKeyEquivalent(with: event)
        #expect(shown.offers == 30, "a text view's chord was offered to \(shown.offers) of 30 pane views")
        #expect(shown.router.decided.offers.windowWalks == 1)
    }

    /// Cmd-G the dispatcher decided while a find bar's field edits in one of 31 panes: the window walks
    /// that pane alone, so the find bar takes it and none of the 30 sibling panes is offered it.
    @Test func aDecidedCmdGInAFindFieldReachesItsPaneAlone() throws {
        let pane = PaneContentView.testing(stripModel: TabStripModel(tabs: [TabItem(id: TabID("find"), title: "Find")]),
                                           reveal: LaunchReveal(deadline: .zero))
        let findBar = FindBarProbe(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        let shown = try Self.shown(pane, responder: findBar.field) { pane.show(findBar) }
        defer { shown.window.close() }
        try #require(findBar.isDescendant(of: pane), "the pane never showed the find bar")
        let editor = try #require(shown.window.firstResponder as? NSTextView)
        try #require(editor.isFieldEditor, "the find field has no field editor")
        let event = try Self.key("g", ignoringModifiers: "g", [.command], keyCode: 5, in: shown.window)
        shown.router.decided.add(event)
        #expect(shown.router.directKeyEquivalentTarget(for: event, firstResponder: editor) === pane)

        #expect(shown.window.performKeyEquivalent(with: event), "nothing took the find field's Cmd-G")
        #expect(findBar.took == 1, "the find bar was asked \(findBar.took) times for one Cmd-G")
        #expect(shown.offers == 0, "the window walked \(shown.offers) sibling pane views for the find field's Cmd-G")
        #expect(shown.router.decided.offers.fieldPane == 2, "one explicit lookup and the window's own")
        #expect(shown.router.decided.offers.windowWalks == 0)
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
        #expect(registry.menuKeyEquivalentCounters.validations == 2, "the debug counter missed a key-down validation")

        // An open menu (no key-down): the gate is not asked, and the item shows enabled.
        counts.dispatching = false
        counts.gateAllows = false
        #expect(validation.validateMenuItem(item), "New Tab shows disabled in the open menu")
        #expect(counts.gate == 2)
        #expect(counts.availability == 2)
        #expect(registry.menuKeyEquivalentCounters.validations == 2, "an open menu's validation counted as a key-down's")
    }

    /// The menu bar skips its search only for a decided key whose chord's items are all registry items
    /// the gate refuses: a responder item (Copy), a system item the gate allows (Quit), a chord with no
    /// item and an undecided key keep AppKit's search; a refused event's second pass asks the gate nothing.
    @Test func theMenuBarSearchesEveryChordItMayNotRefuse() throws {
        let registry = ActionRegistry.standard()
        let counts = Counts()
        registry.bind("newTab.default", isEnabled: { counts.availability += 1; return true }) { counts.ran += 1 }
        registry.bind("quit", isEnabled: { counts.availability += 1; return false }) { counts.ran += 1 }
        registry.isDispatchingKeyDown = { true }
        registry.menuKeyEquivalentGate = { id in
            counts.gate += 1
            return id == "quit"
        }
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let decided = DecidedKeyEvents()
        let bar = Self.bar(registry, [
            try #require(registry.makeMenuItem(for: "newTab.default")), try #require(registry.makeMenuItem(for: "quit")), copy,
        ], decided: decided)
        registry.dispatchingInputEvent = { counts.event }
        func decidedKey(_ key: String, keyCode: UInt16) throws -> NSEvent {
            let event = try Self.key(key, ignoringModifiers: key, [.command], keyCode: keyCode, in: nil)
            decided.add(event)
            return event
        }
        /// The bar's search for `event` while it is the key-down being dispatched, as `CmuxApplication` sends it.
        func press(_ event: NSEvent) -> Bool {
            counts.event = event
            defer { counts.event = nil }
            return bar.performKeyEquivalent(with: event)
        }

        let newTab = try decidedKey("t", keyCode: 17)
        #expect(!press(newTab))
        #expect(!press(newTab), "the second pass of a refused Cmd-T took it")
        #expect(counts.gate == 1, "the gate was asked \(counts.gate) times for one refused Cmd-T")
        #expect(registry.menuKeyEquivalentCounters == MenuKeyEquivalentCounters(searches: 0, skipped: 1, validations: 0))

        _ = press(try decidedKey("q", keyCode: 12))
        _ = press(try decidedKey("c", keyCode: 8))
        _ = press(try decidedKey("j", keyCode: 38))
        _ = press(try Self.key("t", ignoringModifiers: "t", [.command], keyCode: 17, in: nil))
        #expect(registry.menuKeyEquivalentCounters.searches == 4,
                "Quit, Copy, an unbound chord or an undecided Cmd-T lost the menu search")
        #expect(registry.menuKeyEquivalentCounters.skipped == 1)
        #expect(counts.ran == 0, "the menu ran a refused or unavailable action")
    }

    /// Cmd-T the dispatcher decided and gave the focused terminal (it ran nothing for it), in
    /// `NSApplication`'s order (the window, then the main menu when the window declines): the window
    /// asks the terminal alone, the menu gate refuses New Tab once, AppKit validates no item and
    /// checks no availability, and New Tab never runs.
    @Test func aDecidedCmdTValidatesTheMenuAtMostOnce() throws {
        try Self.decidedChordInATerminal(key: "t", keyCode: 17, action: "newTab.default")
    }

    /// The same for Cmd-B (Toggle Left Sidebar), which no Ghostty keybind has: the terminal's menu-first
    /// pass refuses it, the terminal leaves it to its key-down pass, and `NSApplication`'s menu pass
    /// after the window declines asks the gate nothing again.
    @Test func aDecidedCommandChordNoGhosttyKeybindHasSkipsBothMenuPasses() throws {
        let unbound = try Self.decidedChordInATerminal(key: "b", keyCode: 11, action: "toggleSidebar")
        #expect(!unbound.windowTookIt, "the terminal took Cmd-B as a key equivalent")
        #expect(unbound.terminalLeftItToKeyDown, "Cmd-B did not take the terminal's unbound-chord path")
    }

    @discardableResult
    static func decidedChordInATerminal(key: String, keyCode: UInt16, action: ActionID) throws
        -> (windowTookIt: Bool, terminalLeftItToKeyDown: Bool) {
        let (session, io) = try Self.terminal()
        let registry = ActionRegistry.standard()
        let shown = try Self.shown(session.view, responder: session.surfaceView, registry: registry)
        let counts = Counts()
        registry.bind(action, isEnabled: { counts.availability += 1; return true }) { counts.ran += 1 }
        let router = shown.router
        registry.isDispatchingKeyDown = { router.inputDispatch.isKeyDown }
        registry.dispatchingInputEvent = { router.inputDispatch.event }
        registry.menuKeyEquivalentGate = { id in
            counts.gate += 1
            return router.allowsMenuKeyEquivalent(id)
        }
        let item = try #require(registry.makeMenuItem(for: action))
        try #require(item.keyEquivalent == key && item.keyEquivalentModifierMask == [.command],
                     "\(action) is not on Cmd-\(key): \(item.keyEquivalent.debugDescription)")
        let previousMenu = NSApp.mainMenu, previousClaim = TerminalKeyEquivalent.menuMayClaim
        NSApp.mainMenu = Self.bar(registry, [item], decided: router.decided)
        TerminalKeyEquivalent.menuMayClaim = { [weak router] in router?.menuMayClaim($0) ?? true }
        defer {
            NSApp.mainMenu = previousMenu
            TerminalKeyEquivalent.menuMayClaim = previousClaim
            io.finish()
            shown.window.close()
        }
        let event = try Self.key(key, ignoringModifiers: key, [.command], keyCode: keyCode, in: shown.window)
        router.decided.add(event)

        let windowTookIt = router.dispatchingSynthetic(event) { shown.window.performKeyEquivalent(with: event) }
        if !windowTookIt { _ = router.dispatchingSynthetic(event) { NSApp.mainMenu?.performKeyEquivalent(with: event) } }
        #expect(shown.offers == 0, "the window walked \(shown.offers) pane views for the terminal's Cmd-\(key)")
        #expect(counts.gate == 1, "the menu gate was asked \(counts.gate) times for one Cmd-\(key)")
        #expect(registry.menuKeyEquivalentCounters == MenuKeyEquivalentCounters(searches: 0, skipped: 1, validations: 0),
                "the main menu searched or validated a chord the router decided")
        #expect(counts.availability == 0, "a refused Cmd-\(key) checked \(action)'s availability")
        #expect(counts.ran == 0, "the menu ran \(action) for a Cmd-\(key) the router gave the terminal")
        #expect(router.decided.offers.focusedSurface == 1)
        return (windowTookIt, session.surfaceView.lastPerformKeyEventTimestamp == event.timestamp)
    }
}
