import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextSidebar
import Testing

/// The key router's per-window key facts behind a generation counter: a run of chords with
/// no change builds the facts and the `KeyContext` once; each input the lookups are built from rebuilds them and
/// names itself (focus, first responder, file explorer keyboard, top page, sidebar selection crossing one,
/// workspaces as tabs); each flag of an object they found follows that object with no rebuild (marked text, the
/// page's list and editable focus, the suggestion list, copy mode, a read-only markdown file, the editor's key
/// sequence, the Chromium page window). ``KeyFactsSourcesTests`` drives the sources this file does not.
@MainActor @Suite(.serialized)
struct KeyContextCacheTests {
    // MARK: The cache

    private nonisolated struct Stamp: KeyContextStamp {
        var value = 0
        func invalidation(since earlier: Stamp) -> KeyContextInvalidation { .topPage }
    }

    private final class Owner {}

    @Test func aHundredReadsWithNoChangeBuildOnce() {
        let cache = KeyContextCache<Stamp, Int>()
        let owner = Owner()
        for _ in 0..<100 {
            #expect(cache.value(for: owner, stamp: { Stamp() }, build: { (7, Stamp()) }) == 7)
        }
        #expect(cache.builds == 1)
        #expect(cache.lastInvalidation == nil)
    }

    @Test func aChangedStampRebuildsAndNamesItsSource() {
        let cache = KeyContextCache<Stamp, Int>()
        let owner = Owner()
        _ = cache.value(for: owner, stamp: { Stamp() }, build: { (1, Stamp()) })
        let value = cache.value(for: owner, stamp: { Stamp(value: 1) }, build: { (2, Stamp(value: 1)) })
        #expect(value == 2)
        #expect(cache.builds == 2)
        #expect(cache.lastInvalidation == .topPage)
    }

    @Test func invalidateMakesEveryEntryStale() {
        let cache = KeyContextCache<Stamp, Int>()
        let first = Owner(), second = Owner()
        _ = cache.value(for: first, stamp: { Stamp() }, build: { (1, Stamp()) })
        _ = cache.value(for: second, stamp: { Stamp() }, build: { (1, Stamp()) })
        cache.invalidate(.focusTransition)
        #expect(cache.lastInvalidation == .focusTransition)
        _ = cache.value(for: first, stamp: { Stamp() }, build: { (2, Stamp()) })
        _ = cache.value(for: second, stamp: { Stamp() }, build: { (2, Stamp()) })
        #expect(cache.builds == 4)
    }

    @Test func eachOwnerHasItsOwnEntry() {
        let cache = KeyContextCache<Stamp, Int>()
        let first = Owner(), second = Owner()
        #expect(cache.value(for: first, stamp: { Stamp() }, build: { (1, Stamp()) }) == 1)
        #expect(cache.value(for: second, stamp: { Stamp() }, build: { (2, Stamp()) }) == 2)
        #expect(cache.value(for: first, stamp: { Stamp() }, build: { (3, Stamp()) }) == 1)
        #expect(cache.builds == 2)
    }

    @Test func theMemoKeepsItsContextWhileTheInputsAreEqual() {
        let memo = KeyContextMemo<Int, Int>()
        let terminal = KeyContext(bits: .terminalFocused)
        for _ in 0..<100 {
            let context = memo.context(focus: 1, appContext: [], facts: 1, build: { terminal })
            #expect(context == terminal)
        }
        #expect(memo.builds == 1)
        let moved = memo.context(focus: 2, appContext: [], facts: 1, build: { KeyContext() })
        #expect(moved == KeyContext())
        _ = memo.context(focus: 2, appContext: .signedIn, facts: 1, build: { KeyContext() })
        _ = memo.context(focus: 2, appContext: .signedIn, facts: 2, build: { KeyContext() })
        #expect(memo.builds == 4)
    }

    // MARK: Every invalidation source

    /// A stamp that differs from `base` only in `source`'s input. The switch is exhaustive: a new source fails to
    /// compile here until it has its test.
    private static func stamp(changing source: KeyContextInvalidation, from base: KeyRouter.FactsStamp, responder: NSObject) -> KeyRouter.FactsStamp {
        var changed = base
        switch source {
        case .focusTransition: changed.focus.windowKey.toggle()
        case .firstResponder: changed.responder = ObjectIdentifier(responder)
        case .topPage: changed.topPage = .home
        case .sidebarSelection: changed.sidebarMultiSelection.toggle()
        case .workspacesAsTabs: changed.workspacesAsTabs.toggle()
        }
        return changed
    }

    private static var baseStamp: KeyRouter.FactsStamp {
        KeyRouter.FactsStamp(focus: FocusState(), responder: nil, topPage: nil, workspacesAsTabs: false, sidebarMultiSelection: false)
    }

    @Test(arguments: KeyContextInvalidation.allCases)
    func eachSourceRebuildsTheFactsAndNamesItself(_ source: KeyContextInvalidation) {
        let responder = NSObject()
        let changed = Self.stamp(changing: source, from: Self.baseStamp, responder: responder)
        #expect(changed != Self.baseStamp, "\(source) changes no input of the stamp")
        #expect(changed.invalidation(since: Self.baseStamp) == source)

        let cache = KeyContextCache<KeyRouter.FactsStamp, Int>()
        let window = Owner()
        _ = cache.value(for: window, stamp: { Self.baseStamp }, build: { (0, Self.baseStamp) })
        _ = cache.value(for: window, stamp: { changed }, build: { (1, changed) })
        #expect(cache.builds == 2, "\(source) did not rebuild the facts")
        #expect(cache.lastInvalidation == source)
    }

    // MARK: The real router

    struct Harness {
        let services: AppServices
        let controller: WindowController
        let shell: NSWindow
        var router: KeyRouter { services.keyRouter }
        func facts() -> KeyRouter.Facts { router.facts(in: shell, controller: controller) }
        func close() { for controller in services.windows.controllers { controller.window?.close() } }
        var builds: Int { router.keyFactsCache.builds }

        /// Makes `sources` the objects the shell's cached facts read, as a build under the window's focus
        /// that found them would: a unit test has no pane content (a terminal, a browser, a page) for the
        /// build to find. Returns the build count after it.
        func seed(_ sources: KeyRouter.FactSources) -> Int {
            router.keyFactsCache.invalidate(.focusTransition)
            let stamp = router.keyFactsStamp(in: shell, controller: controller)
            _ = router.keyFactsCache.value(for: shell, stamp: { stamp }, build: {
                (KeyRouter.CachedFacts(facts: KeyRouter.Facts(), sources: sources), stamp)
            })
            return builds
        }

        /// The window's focus and the cache's generation now (``expected(_:since:)``).
        struct Mark {
            let focus: FocusState
            let generation: UInt64
        }

        func mark() -> Mark { Mark(focus: controller.focus.state, generation: router.keyFactsCache.generation) }

        /// The source the cache names for a change of `source`'s input since `mark`. The window reports a new
        /// first responder to the focus machine, so a focus move or settle that the change caused comes first.
        func expected(_ source: KeyContextInvalidation, since mark: Mark) -> KeyContextInvalidation {
            controller.focus.state != mark.focus || router.keyFactsCache.generation != mark.generation ? .focusTransition : source
        }
    }

    static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["cache-workspace"]))
        let shell = try #require(controller.window)
        controller.focus.send(.topology(FocusTopology(workspace: "cache-workspace", panes: [
            .init(id: "cache-pane", tabs: [.init(id: "cache-tab", kind: .terminal)], selected: "cache-tab"),
            .init(id: "cache-other", tabs: [.init(id: "cache-other-tab", kind: .terminal)], selected: "cache-other-tab"),
        ])))
        controller.focus.send(.focusPane("cache-pane", source: .keyboard))
        try #require(controller.focus.state.resolved == .terminal(pane: "cache-pane", tab: "cache-tab"))
        return Harness(services: services, controller: controller, shell: shell)
    }

    @Test func aHundredChordsWithNoChangeBuildTheFactsAndContextOnce() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let facts = harness.facts()
        let builds = harness.router.keyFactsCache.builds
        let focus = harness.controller.focus.state
        let context = harness.router.keyContext(for: focus, facts: facts)
        let contextBuilds = harness.router.keyContextMemo.builds
        for _ in 0..<100 {
            let again = harness.facts()
            #expect(again == facts)
            #expect(harness.router.keyContext(for: focus, facts: again) == context)
        }
        #expect(harness.router.keyFactsCache.builds == builds, "100 chords with no change rebuilt the facts")
        #expect(harness.router.keyContextMemo.builds == contextBuilds, "100 chords with no change rebuilt the context")
    }

    @Test func aHundredUnboundChordsThroughTheRouterBuildTheFactsOnce() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        var timestamp: TimeInterval = 9000
        func chord() throws -> NSEvent {
            timestamp += 1
            return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control, .option, .shift],
                                                 timestamp: timestamp, windowNumber: harness.shell.windowNumber, context: nil,
                                                 characters: "\u{F70F}", charactersIgnoringModifiers: "\u{F70F}", isARepeat: false,
                                                 keyCode: 111))
        }
        try #require(harness.services.registry.resolveShortcut(for: try chord()) == nil, "Cmd-Ctrl-Opt-Shift-F12 is bound")
        _ = harness.facts()
        let builds = harness.router.keyFactsCache.builds
        for _ in 0..<100 {
            let event = try chord()
            _ = harness.router.dispatchingSynthetic(event) { harness.router.interceptKeyDown(event, in: harness.shell) }
        }
        #expect(harness.router.keyFactsCache.builds == builds, "100 unbound chords rebuilt the facts")
    }

    @Test func aFocusMoveRebuildsTheFacts() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        _ = harness.facts()
        let builds = harness.router.keyFactsCache.builds
        harness.controller.focus.send(.focusPane("cache-other", source: .keyboard))
        try #require(harness.controller.focus.state.resolved == .terminal(pane: "cache-other", tab: "cache-other-tab"))
        _ = harness.facts()
        #expect(harness.router.keyFactsCache.builds == builds + 1)
        #expect(harness.router.keyFactsCache.lastInvalidation == .focusTransition)
    }

    @Test func aFocusSettleBumpsTheGeneration() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        _ = harness.facts()
        let builds = harness.router.keyFactsCache.builds
        let generation = harness.router.keyFactsCache.generation
        harness.router.focusDidSettle(harness.controller.focus.state, in: harness.shell)
        #expect(harness.router.keyFactsCache.generation != generation)
        _ = harness.facts()
        #expect(harness.router.keyFactsCache.builds == builds + 1)
        #expect(harness.router.keyFactsCache.lastInvalidation == .focusTransition)
    }

    @Test func theSidebarSelectionRebuildsOnlyWhenItCrossesOne() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let model = harness.controller.sidebar.model
        model.selection = [WorkspaceID("cache-a")]
        #expect(!harness.facts().sidebarMultiSelection)
        let builds = harness.router.keyFactsCache.builds
        model.selection = [WorkspaceID("cache-a"), WorkspaceID("cache-b")]
        #expect(harness.facts().sidebarMultiSelection)
        #expect(harness.router.keyFactsCache.builds == builds + 1)
        #expect(harness.router.keyFactsCache.lastInvalidation == .sidebarSelection)
        model.selection = [WorkspaceID("cache-a"), WorkspaceID("cache-b"), WorkspaceID("cache-c")]
        #expect(harness.facts().sidebarMultiSelection)
        #expect(harness.router.keyFactsCache.builds == builds + 1, "a selection that stayed above one rebuilt the facts")
        model.selection = [WorkspaceID("cache-a")]
        #expect(!harness.facts().sidebarMultiSelection)
        #expect(harness.router.keyFactsCache.builds == builds + 2)
    }

    @Test func aFirstResponderChangeRebuildsAndMarkedTextStaysLive() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        try #require(harness.shell.contentView).addSubview(field)
        _ = harness.facts()
        let builds = harness.router.keyFactsCache.builds
        try #require(harness.shell.makeFirstResponder(field))
        #expect(!harness.facts().hasMarkedText)
        #expect(harness.router.keyFactsCache.builds == builds + 1, "a new first responder did not rebuild the facts")
        // An input method composing changes no cached input: the facts are not rebuilt, yet they say so.
        field.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.facts().hasMarkedText, "marked text is not read live")
        field.unmarkText()
        #expect(!harness.facts().hasMarkedText)
        #expect(harness.router.keyFactsCache.builds == builds + 1)
    }

    @Test func anAppContextChangeRebuildsTheContext() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let facts = harness.facts()
        let focus = harness.controller.focus.state
        _ = harness.router.keyContext(for: focus, facts: facts)
        let builds = harness.router.keyContextMemo.builds
        let signedIn = harness.services.registry.context.contains(.signedIn)
        if signedIn { harness.services.registry.context.remove(.signedIn) } else { harness.services.registry.context.insert(.signedIn) }
        defer { if signedIn { harness.services.registry.context.insert(.signedIn) } else { harness.services.registry.context.remove(.signedIn) } }
        let context = harness.router.keyContext(for: focus, facts: facts)
        #expect(harness.router.keyContextMemo.builds == builds + 1)
        #expect(context.bits.contains(.signedIn) == !signedIn)
    }
}
