import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// A held New Tab key: the system repeats its key-down, and each repeat opened a tab with its own page view (a web
/// view). With the frame rule alone (`NewTabPageAtItsFrameTests`) a repeat still makes a page for each tab that a
/// frame showed: the repeats come slower than the frames.
///
/// The rule for a repeat (decision 2026-11-16): a New Tab key that is a system repeat makes a tab with no page. The
/// page of the selected tab is made at the first frame after the hold ends. The hold ends at an event of the system,
/// never at a timer:
///
/// - the key-up of the held key;
/// - a flags event after which a modifier of the held key is no longer down (Command up);
/// - a key-down that is no repeat, or a repeat of another key;
/// - the app is no longer the active app.
///
/// The flags event is a usual end, not a corner: a person often lifts Command before the key, and then no key-up of
/// the key with Command comes (`commandUpBeforeTheKeyMakesThePageAtTheNextFrame`).
///
/// A single key is not a repeat: it starts no hold, and its page comes as before.
///
/// The events here are made in the test and go through the app's input dispatch context, the one place that gets
/// each event of `NSApplication.sendEvent`. That macOS hands the app each of these events for a real held Cmd-T is
/// NOT proven here. For the key-up of a key while Command is down, the proof is a read of a real app's input
/// journal (2026-11-16): key-ups with Command down came for shortcut letters; none of them was the T key.
///
/// Frames are the app's own, and a test waits for one by an event (`NewTabPageAtItsFrameTests.frame`). No wait
/// polls and no wait reads a clock: a page that the rule gives a tab comes at ONE frame, and a test asks after
/// that one frame.
///
/// The engine: each page view here is a real one, and each test prints the engine of each page view that it made
/// (`engine-of-test:` in the run's output, with the case's name). The package's tests have no Chromium host, so
/// that engine is WebKit: a pass here holds the rule of the host code, and is no proof of the look or the times of
/// a Chromium page.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabRepeatKeyTests {
    /// Key code of T, and of A (another key).
    private static let keyT: UInt16 = 17, keyA: UInt16 = 0

    /// An event of the keyboard, as AppKit hands it to the application.
    private static func event(_ type: NSEvent.EventType, code: UInt16 = keyT, repeats: Bool = false, flags: NSEvent.ModifierFlags = .command,
                              in window: NSWindow) throws -> NSEvent {
        let text = type == .flagsChanged ? "" : (code == keyT ? "t" : "a")
        return try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: text,
                                             charactersIgnoringModifiers: text, isARepeat: repeats, keyCode: code),
                            "AppKit made no \(type) event")
    }

    /// Dispatches `event` as the application does: `body` runs with it as the event in dispatch.
    private static func send(_ event: NSEvent, _ services: AppServices, _ body: () -> Void = {}) {
        services.inputDispatch.dispatching(event, body)
    }

    /// The New Tab key goes down in `pane`: the first key-down of a press (no repeat), or one of the system's repeats.
    private static func newTabKey(repeats: Bool, in pane: PaneController, _ window: NSWindow, _ services: AppServices) throws {
        send(try event(.keyDown, repeats: repeats, in: window), services) { NewTabPage.open(in: pane, seed: nil) }
    }

    /// A press and `repeats` repeats of the New Tab key, with a frame after each key. Returns the count of page
    /// views after the press's own page: the repeats must add none to it. The fixture counts the repeats' tabs by
    /// the store's entries, not by their keys: the store can give a tab a new key between two frames.
    private static func heldNewTabKey(repeats: Int, in pane: PaneController, _ window: NSWindow, _ services: AppServices,
                                      _ built: () -> Int) async throws -> Int {
        let tabs = services.agentTabs
        let start = built()
        try newTabKey(repeats: false, in: pane, window, services)
        await NewTabPageAtItsFrameTests.frame(services)
        try #require(built() == start + 1, "fixture: the press of the key (no repeat) had \(built() - start) page views at its frame")
        let before = tabs.newTabPages.keys
        for _ in 0..<repeats {
            try newTabKey(repeats: true, in: pane, window, services)
            await NewTabPageAtItsFrameTests.frame(services)
        }
        let after = tabs.newTabPages.keys
        let opened = after.count - before.count
        try #require(opened == repeats, "fixture: the \(repeats) repeats opened \(opened) New Tab pages; the keys before \(before), after \(after)")
        return start + 1
    }

    /// After the hold's end: one page view more at the first frame, for the tab that the pane has selected, and no
    /// other one in the 3 frames after it.
    private static func expectOnePageForTheSelectedTab(after held: Int, _ why: String, in pane: PaneController, _ services: AppServices,
                                                       _ built: () -> Int) async {
        await NewTabPageAtItsFrameTests.frame(services)
        #expect(built() == held + 1, "\(built() - held) page views were made by the first frame after \(why); exactly one is right")
        for _ in 0..<3 { await NewTabPageAtItsFrameTests.frame(services) }
        #expect(built() == held + 1, "\(built() - held) page views were made by the fourth frame after \(why); exactly one is right")
        let selected = pane.stripModel.selectedID?.rawValue
        #expect(pane.currentTabKey == selected, "the pane does not show its selected tab after \(why)")
        #expect(selected.map { services.agentTabs.existingView($0) != nil } == true, "the selected tab has no page view after \(why)")
    }

    /// Five repeats with a frame after each: no repeat's tab gets a page view while the key is down, also not at
    /// an event that is no end of the hold. The key-up then makes one, at a frame and not in its own turn.
    @Test func repeatsOfTheNewTabKeyMakeNoPageViewUntilTheKeyIsUp() async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-repeat-key-run") { services, window, pane, built in
            let held = try await Self.heldNewTabKey(repeats: 5, in: pane, window, services, built)
            #expect(built() == held, "\(built() - held) page views were made for the tabs of 5 repeats, with the key still down")

            // No end of the hold: Shift goes down (Command stays down), and another key goes up.
            Self.send(try Self.event(.flagsChanged, code: 56, flags: [.command, .shift], in: window), services)
            Self.send(try Self.event(.keyUp, code: Self.keyA, flags: .command, in: window), services)
            for _ in 0..<3 { await NewTabPageAtItsFrameTests.frame(services) }
            #expect(built() == held, "\(built() - held) page views were made at an event that does not end the hold")

            Self.send(try Self.event(.keyUp, in: window), services)
            #expect(built() == held, "\(built() - held) page views were made in the key-up's own turn, before a frame")
            await Self.expectOnePageForTheSelectedTab(after: held, "the key-up", in: pane, services, built)
        }
    }

    /// An end of a hold, by the event that the system gives.
    enum HoldEnd: String, CaseIterable, Sendable {
        case keyUp, commandUp, anotherKey, repeatOfAnotherKey, appResignsActive
    }

    /// Each end makes exactly one page view, for the selected tab.
    @Test(arguments: HoldEnd.allCases) func eachEndOfAHeldNewTabKeyMakesOnePageViewForTheSelectedTab(_ end: HoldEnd) async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-repeat-key-end-\(end.rawValue)") { services, window, pane, built in
            let held = try await Self.heldNewTabKey(repeats: 3, in: pane, window, services, built)
            #expect(built() == held, "\(built() - held) page views were made for the tabs of 3 repeats, with the key still down")
            switch end {
            case .keyUp: Self.send(try Self.event(.keyUp, in: window), services)
            case .commandUp: Self.send(try Self.event(.flagsChanged, code: 55, flags: [], in: window), services)
            case .anotherKey: Self.send(try Self.event(.keyDown, code: Self.keyA, flags: [], in: window), services)
            case .repeatOfAnotherKey: Self.send(try Self.event(.keyDown, code: Self.keyA, repeats: true, flags: [], in: window), services)
            case .appResignsActive:
                // A key router of this app's input dispatch context on the test's own center: a post to the default
                // center reaches each observer of the test process. The router's init wires the observer under test.
                let center = NotificationCenter()
                let router = KeyRouter(registry: services.registry, inputDispatch: services.inputDispatch, center: center)
                withExtendedLifetime(router) { center.post(name: NSApplication.didResignActiveNotification, object: nil) }
            }
            await Self.expectOnePageForTheSelectedTab(after: held, "the end \(end.rawValue)", in: pane, services, built)
        }
    }

    /// A person lifts Command first. No key-up of the key with Command comes: the flags event is the end. The system
    /// then repeats the plain key (typed text, it opens nothing) and hands its key-up with no Command: neither
    /// makes a second page view.
    @Test func commandUpBeforeTheKeyMakesThePageAtTheNextFrame() async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-repeat-key-command-first") { services, window, pane, built in
            let held = try await Self.heldNewTabKey(repeats: 3, in: pane, window, services, built)
            #expect(built() == held, "\(built() - held) page views were made for the tabs of 3 repeats, with the key still down")
            Self.send(try Self.event(.flagsChanged, code: 55, flags: [], in: window), services)
            #expect(built() == held, "\(built() - held) page views were made in the flags event's own turn, before a frame")
            await NewTabPageAtItsFrameTests.frame(services)
            #expect(built() <= held + 1, "\(built() - held) page views were made at the first frame after Command went up")
            for _ in 0..<2 { Self.send(try Self.event(.keyDown, repeats: true, flags: [], in: window), services) }
            Self.send(try Self.event(.keyUp, flags: [], in: window), services)
            await Self.expectOnePageForTheSelectedTab(after: held, "Command up, then the plain key's repeats and its key-up", in: pane, services, built)
        }
    }

    /// A press with no repeat starts no hold: its page comes at a frame with no key-up, no flags event and no other
    /// key. So does the page of a second press (a system that hands the app no key-up delays nothing).
    @Test func aSingleNewTabKeyStartsNoHold() async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-repeat-key-single") { services, window, pane, built in
            for press in 1...2 {
                let before = built()
                try Self.newTabKey(repeats: false, in: pane, window, services)
                await NewTabPageAtItsFrameTests.frame(services)
                #expect(built() == before + 1, "press \(press) of the key (no repeat) had \(built() - before) page views at its frame, with no end event")
                #expect(pane.currentTabKey == pane.stripModel.selectedID?.rawValue, "the pane does not show the tab of press \(press)")
            }
        }
    }

    /// The window's key hold for the new tab's field has a limit (2 s). A held New Tab key can pass it: the limit
    /// ends the key hold, makes no page, and the page still comes at the hold's end.
    @Test func aHoldOverTheKeyHoldsLimitStillGetsItsPageAtItsEnd() async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-repeat-key-limit") { services, window, pane, built in
            let input = services.keyRouter.newTabInputCoordinator
            // The limit's clock and its deadline are the test's: no wait of 2 s.
            let began = ContinuousClock.now
            var now = began, deadlines: [@MainActor @Sendable () -> Void] = []
            let (wiredNow, wiredDeadline) = (input.now, input.scheduleDeadline)
            input.now = { now }
            input.scheduleDeadline = { _, fire in
                deadlines.append(fire)
                return Task {}
            }
            defer { (input.now, input.scheduleDeadline) = (wiredNow, wiredDeadline) }

            let held = try await Self.heldNewTabKey(repeats: 3, in: pane, window, services, built)
            #expect(built() == held, "\(built() - held) page views were made for the tabs of 3 repeats, with the key still down")
            try #require(input.isHolding(in: window), "fixture: the last repeat began no key hold: \(input.log.suffix(4))")
            now = began + input.holdLimit + .seconds(1)
            let last = try #require(deadlines.last, "the key hold asked for no deadline")
            last()
            #expect(!input.isHolding(in: window), "the key hold outlived its limit: \(input.log.suffix(4))")
            for _ in 0..<3 { await NewTabPageAtItsFrameTests.frame(services) }
            #expect(built() == held, "\(built() - held) page views were made at the key hold's limit, with the key still down")

            Self.send(try Self.event(.flagsChanged, code: 55, flags: [], in: window), services)
            await Self.expectOnePageForTheSelectedTab(after: held, "Command up, past the key hold's limit", in: pane, services, built)
            // Not a claim of this test: where the keyboard is then. The run's output has it.
            print("keyboard-after-long-hold: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        }
    }

    /// A repeat takes no page out of the pool: the parked page stays while the key is down. The tab of the hold's
    /// end is the next open: it adopts the parked page at its frame. Limit: after that the pool has no parked page
    /// until its own refill made one, as after each open that adopts a page.
    @Test func aRepeatOfTheNewTabKeyLeavesTheParkedPageInThePool() async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-repeat-key-pool") { services, window, pane, built in
            let pool = services.newTabSpares
            let folder = FileManager.default.temporaryDirectory.appending(path: "repeat-key-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let html = folder.appending(path: "index.html")
            try Data("<html><body>New Tab spare fixture</body></html>".utf8).write(to: html)
            var made: [AgentPaneView] = []
            defer {
                pool.makeSpare = { _ in nil } // the fixture ends it; no timer of the pool makes a real page meanwhile
                pool.dropAll()
                made.forEach { $0.close() }
                try? FileManager.default.removeItem(at: folder)
            }
            // An inert page stands in for the pool's: the pool's own timing parks it. The pool parks a page in the
            // turn that made it, so the next turn of the main queue sees it parked.
            let parked: AgentPaneView = await withCheckedContinuation { (first: CheckedContinuation<AgentPaneView, Never>) in
                var waiting: CheckedContinuation<AgentPaneView, Never>? = first
                pool.makeSpare = { page in
                    let model = AgentPaneModel(host: services.agentTabs.host, newTab: page)
                    guard let view = AgentPaneView(model: model, source: .bundled(html)) else { return nil }
                    made.append(view)
                    if let told = waiting {
                        waiting = nil
                        DispatchQueue.main.async { told.resume(returning: view) }
                    }
                    return view
                }
                pool.retarget(window)
                pool.prewarm()
                pool.start()
            }
            try #require(pool.spare?.view === parked, "fixture: the made page is not the pool's parked page")

            let before = built()
            try Self.newTabKey(repeats: true, in: pane, window, services)
            #expect(pool.spare?.view === parked, "a repeat of the New Tab key took the parked page out of the pool")
            #expect(built() == before, "\(built() - before) page views were made in a repeat's own turn")
            Self.send(try Self.event(.keyUp, in: window), services)
            await Self.expectOnePageForTheSelectedTab(after: before, "the key-up", in: pane, services, built)
            let selected = try #require(pane.stripModel.selectedID?.rawValue, "the pane has no selected tab after the key-up")
            #expect(services.agentTabs.existingView(selected) === parked, "the tab of the hold's end did not adopt the parked page")
            #expect(pool.spare?.view !== parked, "the parked page is still the pool's after the tab of the hold's end adopted it")
        }
    }

    /// The next Cmd-N's reservation is idle work, and it can come while the key is down (the fixture makes the
    /// launch's reservation before it counts). The page view of a reservation is for a tab that no pane has: it is no
    /// page of a repeat's tab, and the hold's end still makes exactly one page, for the selected tab.
    @Test func aReservationMadeWhileTheKeyIsHeldMakesItsOwnPageAndNoneForARepeatsTab() async throws {
        try await NewTabPageAtItsFrameTests.withThePagesOfAnEmptyPool("cn-repeat-key-reserve") { services, window, pane, pages in
            let tabs = services.agentTabs, daemon = services.daemon
            let built = { pages().count }
            let held = try await Self.heldNewTabKey(repeats: 3, in: pane, window, services, built)
            #expect(built() == held, "\(built() - held) page views were made for the tabs of 3 repeats, with the key still down")

            // The reservation goes and is made again in one turn, with the key still down. The pool is empty, so the
            // reservation builds its page now.
            tabs.releaseReservedWorkspace(on: daemon.store, .unshown)
            services.newTabSpares.dropAll()
            _ = try #require(tabs.reserveWorkspace(on: daemon, cwd: nil), "fixture: no Cmd-N workspace was reserved with the key down")
            let reserved = try #require(daemon.store.reservedWorkspace?.tabKey, "fixture: the reservation has no tab")
            let made = pages().dropFirst(held).map { $0.key }
            #expect(made == [reserved], "the reservation made with the key down built \(made.count) page views; one, for its own tab \(reserved), is right: \(made)")
            #expect(!pane.pane.tabs.contains { $0.id == reserved }, "the reservation's tab is a tab of the pane")
            for _ in 0..<3 { await NewTabPageAtItsFrameTests.frame(services) }
            #expect(built() == held + 1, "\(built() - held - 1) page views were made for the repeats' tabs after the reservation, with the key still down")

            Self.send(try Self.event(.keyUp, in: window), services)
            #expect(built() == held + 1, "\(built() - held - 1) page views were made in the key-up's own turn, before a frame")
            await Self.expectOnePageForTheSelectedTab(after: held + 1, "the key-up, after a reservation with the key down", in: pane, services, built)
        }
    }

    // MARK: Trace (a branch that never merges)

    /// TRACE: the pane's state in one line of the run's output.
    private static func trace(_ at: String, _ name: String, in pane: PaneController, _ services: AppServices,
                              _ pages: () -> [NewTabPageAtItsFrameTests.BuiltPage]) {
        let tabs = services.agentTabs
        let selected: String? = pane.stripModel.selectedID?.rawValue
        let selectedText: String = selected ?? "nil"
        let shownText: String = pane.currentTabKey ?? "nil"
        let selectedIsNewTab: Bool = selected.map { tabs.isNewTabPage($0) } ?? false
        let selectedHasView: Bool = selected.map { tabs.existingView($0) != nil } ?? false
        let record: [String] = pane.pane.tabs.map { $0.id }
        let reserved: String = services.daemon.store.reservedWorkspace?.tabKey ?? "none"
        let holdOn: Bool = services.inputDispatch.newTabHold.isOn
        // One statement for each part: a long sum of strings is slow to type-check.
        var line: String = "hold-trace: \(name) | \(at) | built=\(pages().count) holdOn=\(holdOn)"
        line += " selected=\(selectedText) shown=\(shownText) selectedIsNewTab=\(selectedIsNewTab) selectedHasView=\(selectedHasView)"
        line += " stale=\(pane.stripIsStale) alive=\(pane.selectedContentIsAlive) suspended=\(pane.isSuspended) focused=\(pane.isFocusedInWorkspace)"
        line += " stripTabs=\(pane.orderedIDs.count) record=\(record) reserved=\(reserved)"
        print(line)
    }

    /// TRACE: each end of a hold 3 times. No assert: the run's output has the pane's state before the press, after
    /// the repeats, in the end's own turn and at each of the 4 frames after it, then the journal's content records
    /// (each show of a tab by the pane) since the press. The fixture prints each built page view at its exit.
    @Test(arguments: HoldEnd.allCases, [1, 2, 3])
    func traceOfEachEndOfAHeldNewTabKey(end: HoldEnd, round: Int) async throws {
        let name = "cn-repeat-key-trace-\(end.rawValue)-\(round)"
        try await NewTabPageAtItsFrameTests.withThePagesOfAnEmptyPool(name) { services, window, pane, pages in
            let mark = SplitOfPendingSplitTests.journalMark()
            let built = { pages().count }
            Self.trace("before the press", name, in: pane, services, pages)
            _ = try await Self.heldNewTabKey(repeats: 3, in: pane, window, services, built)
            Self.trace("after 3 repeats", name, in: pane, services, pages)
            switch end {
            case .keyUp: Self.send(try Self.event(.keyUp, in: window), services)
            case .commandUp: Self.send(try Self.event(.flagsChanged, code: 55, flags: [], in: window), services)
            case .anotherKey: Self.send(try Self.event(.keyDown, code: Self.keyA, flags: [], in: window), services)
            case .repeatOfAnotherKey: Self.send(try Self.event(.keyDown, code: Self.keyA, repeats: true, flags: [], in: window), services)
            case .appResignsActive:
                let center = NotificationCenter()
                let router = KeyRouter(registry: services.registry, inputDispatch: services.inputDispatch, center: center)
                withExtendedLifetime(router) { center.post(name: NSApplication.didResignActiveNotification, object: nil) }
            }
            Self.trace("the end's own turn", name, in: pane, services, pages)
            for frame in 1...4 {
                await NewTabPageAtItsFrameTests.frame(services)
                Self.trace("frame \(frame) after the end", name, in: pane, services, pages)
            }
            for entry in InputJournal.shared.entries() where entry.seq > mark {
                if case let .content(tab, event) = entry.kind {
                    print("hold-trace: \(name) | journal \(entry.seq) at \(entry.uptimeNanos / 1_000_000) ms | tab=\(tab) \(event)")
                }
            }
        }
    }
}
