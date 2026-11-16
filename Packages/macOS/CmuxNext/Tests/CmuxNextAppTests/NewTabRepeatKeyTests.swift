import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Darwin
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
/// A single key is not a repeat: it starts no hold, and its page comes as before. So does a repeat that the app
/// gets again later than the system made it, when an end of its hold can be in the past: a repeat older than the
/// newest key-up, flags event or key-down with no repeat flag (of any key), and a repeat that the app got before
/// it resigned. The hold is one for all panes, and its end shows each pane that waited.
///
/// The events here are made in the test and go through the app's input dispatch context, the one place that gets
/// each event of `NSApplication.sendEvent`. That macOS hands the app each of these events for a real held Cmd-T is
/// NOT proven here. For the key-up of a key while Command is down, the proof is a read of a real app's input
/// journal (2026-11-16): key-ups with Command down came for shortcut letters; none of them was the T key.
///
/// Frames are the app's own, and a test waits for one by an event (`NewTabPageAtItsFrameTests.frame`). No wait
/// for a page polls and no wait for a page reads a clock: a page that the rule gives a tab comes at ONE frame, and
/// a test asks after that one frame. One fixture wait is of another kind and says so: the wait for a second pane
/// of the store (`theEndOfAHoldGivesEachPaneThePageOfItsSelectedTab`), where two pages also come at two frames.
///
/// The engine: each page view here is a real one, and each test prints the engine of each page view that it made
/// (`engine-of-test:` in the run's output, with the case's name). The package's tests have no Chromium host, so
/// that engine is WebKit: a pass here holds the rule of the host code, and is no proof of the look or the times of
/// a Chromium page.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabRepeatKeyTests {
    /// Key code of T, of A (another key) and of W (the close key).
    private static let keyT: UInt16 = 17, keyA: UInt16 = 0, keyW: UInt16 = 13

    /// An event of the keyboard, as AppKit hands it to the application. Its time is the time when the test made
    /// it, or `time`: the time that the system gave it, for an event that the app gets again later.
    private static func event(_ type: NSEvent.EventType, code: UInt16 = keyT, repeats: Bool = false, flags: NSEvent.ModifierFlags = .command,
                              in window: NSWindow, at time: TimeInterval? = nil) throws -> NSEvent {
        let letter: String = code == keyT ? "t" : (code == keyW ? "w" : "a")
        let text: String = type == .flagsChanged ? "" : letter
        let stamp: TimeInterval = time ?? ProcessInfo.processInfo.systemUptime
        return try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: stamp,
                                             windowNumber: window.windowNumber, context: nil, characters: text,
                                             charactersIgnoringModifiers: text, isARepeat: repeats, keyCode: code),
                            "AppKit made no \(type) event")
    }

    /// Dispatches `event` as the application does: `body` runs with it as the event in dispatch.
    private static func send(_ event: NSEvent, _ services: AppServices, _ body: () -> Void = {}) {
        services.inputDispatch.dispatching(event, body)
    }

    /// The app is no longer the active app. A key router of this app's input dispatch context on the test's own
    /// center: a post to the default center reaches each observer of the test process. The router's init wires the
    /// observer under test.
    private static func resignActive(_ services: AppServices) {
        let center = NotificationCenter()
        let router = KeyRouter(registry: services.registry, inputDispatch: services.inputDispatch, center: center)
        withExtendedLifetime(router) { center.post(name: NSApplication.didResignActiveNotification, object: nil) }
    }

    /// The New Tab key goes down in `pane`: the first key-down of a press (no repeat), or one of the system's repeats.
    /// `answered` gets the key that the store gave the tab, when the store answered the open.
    private static func newTabKey(repeats: Bool, in pane: PaneController, _ window: NSWindow, _ services: AppServices,
                                  answered: (@MainActor (String) -> Void)? = nil) throws {
        send(try event(.keyDown, repeats: repeats, in: window), services) { NewTabPage.open(in: pane, seed: nil, then: answered) }
    }

    /// The store's answer for one open, as an event: a test waits for it with no poll and no clock. When the store
    /// never answers, the wait ends at the suite's time limit.
    @MainActor private final class StoreAnswer {
        private var key: String?
        private var waiting: CheckedContinuation<String, Never>?

        /// The store answered: the tab has the key `key` now.
        func came(_ key: String) {
            self.key = key
            waiting?.resume(returning: key)
            waiting = nil
        }

        /// The key that the store gave the tab, when the store answered.
        func value() async -> String {
            if let key { return key }
            return await withCheckedContinuation { (told: CheckedContinuation<String, Never>) in
                self.waiting = told
            }
        }
    }

    /// The pane's state in words, for a failure's text: what decides if the pane makes the page of its selected tab.
    private static func state(of pane: PaneController, _ services: AppServices) -> String {
        let tabs = services.agentTabs
        let selected: String? = pane.stripModel.selectedID?.rawValue
        let selectedText: String = selected ?? "nil"
        let shownText: String = pane.currentTabKey ?? "nil"
        let selectedIsNewTab: Bool = selected.map { tabs.isNewTabPage($0) } ?? false
        let selectedHasView: Bool = selected.map { tabs.existingView($0) != nil } ?? false
        let record: [String] = pane.pane.tabs.map { $0.id }
        let holdOn: Bool = services.inputDispatch.newTabHold.isOn
        // One statement for each part: a long sum of strings is slow to type-check.
        var line: String = "holdOn=\(holdOn) selected=\(selectedText) shown=\(shownText)"
        line += " selectedIsNewTab=\(selectedIsNewTab) selectedHasView=\(selectedHasView)"
        line += " stale=\(pane.stripIsStale) alive=\(pane.selectedContentIsAlive) suspended=\(pane.isSuspended)"
        line += " focused=\(pane.isFocusedInWorkspace) stripTabs=\(pane.orderedIDs.count) record=\(record)"
        return line
    }

    /// A press and `repeats` repeats of the New Tab key, with a frame after each key. Returns the count of page
    /// views after the press's own page: the repeats must add none to it. The fixture counts the repeats' tabs by
    /// the store's entries, not by their keys: the store can give a tab a new key between two frames.
    /// `beforeTheLastRepeat` runs in the turn before the last repeat's key; `lastAnswered` gets the key that the
    /// store gave the last repeat's tab, when the store answered (`StoreAnswerOrder`).
    private static func heldNewTabKey(repeats: Int, in pane: PaneController, _ window: NSWindow, _ services: AppServices,
                                      beforeTheLastRepeat: () -> Void = {}, lastAnswered: (@MainActor (String) -> Void)? = nil,
                                      _ built: () -> Int) async throws -> Int {
        let tabs = services.agentTabs
        let start = built()
        try newTabKey(repeats: false, in: pane, window, services)
        await NewTabPageAtItsFrameTests.frame(services)
        try #require(built() == start + 1, "fixture: the press of the key (no repeat) had \(built() - start) page views at its frame")
        let before = tabs.newTabPages.keys
        for index in 0..<repeats {
            let isLast = index == repeats - 1
            if isLast { beforeTheLastRepeat() }
            try newTabKey(repeats: true, in: pane, window, services, answered: isLast ? lastAnswered : nil)
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
        let first = state(of: pane, services)
        #expect(built() == held + 1,
                "\(built() - held) page views were made by the first frame after \(why); exactly one is right; the pane then: \(first)")
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

    /// When the store answers the open of the last repeat's tab, against the hold's end. At its answer the store
    /// gives the tab its own key in place of the provisional one, and the pane's selection goes to that key. With
    /// no order of the test's own, the answer comes when the daemon is ready: after the page of the hold's end in
    /// most runs, before the end in some. The test owns the order, by an event and with no wait on a clock
    /// (decision 2026-11-16):
    ///
    /// - `aFrameBeforeTheEnd`, `inTheTurnBeforeTheEnd`: the test waits for the answer (the open's own `then`), and
    ///   then sends the end, after one frame or with no frame between;
    /// - `afterTheEnd`: the daemon's process is stopped from before the last repeat until the asserts of the end
    ///   ran, so no answer can come; then it runs again, and the test waits for the answer.
    enum StoreAnswerOrder: String, CaseIterable, Sendable {
        case aFrameBeforeTheEnd, inTheTurnBeforeTheEnd, afterTheEnd
    }

    /// Each end makes exactly one page view, for the selected tab, in each order of the store's answer.
    @Test(arguments: HoldEnd.allCases, StoreAnswerOrder.allCases)
    func eachEndOfAHeldNewTabKeyMakesOnePageViewForTheSelectedTab(end: HoldEnd, answer order: StoreAnswerOrder) async throws {
        let install = "cn-repeat-key-end-\(end.rawValue)-\(order.rawValue)"
        try await NewTabPageAtItsFrameTests.withAnEmptyPool(install) { services, window, pane, built in
            let tabs = services.agentTabs
            let answer = StoreAnswer()
            let daemon = try #require(services.daemon.identity?.pid, "fixture: the daemon has no process id")
            var stopped = false
            defer { if stopped { kill(daemon, SIGCONT) } } // a throw never leaves the daemon stopped
            let held = try await Self.heldNewTabKey(repeats: 3, in: pane, window, services,
                                                    beforeTheLastRepeat: { if order == .afterTheEnd { stopped = kill(daemon, SIGSTOP) == 0 } },
                                                    lastAnswered: { answer.came($0) }, built)
            #expect(built() == held, "\(built() - held) page views were made for the tabs of 3 repeats, with the key still down")
            if order == .afterTheEnd {
                try #require(stopped, "fixture: the daemon's process did not stop")
            } else {
                let real = await answer.value()
                try #require(!ProvisionalTab.isProvisional(real) && tabs.isNewTabPage(real),
                             "fixture: the store's answer \(real) is no New Tab page with a key of the store")
                if order == .aFrameBeforeTheEnd { await NewTabPageAtItsFrameTests.frame(services) }
                #expect(built() == held, "\(built() - held) page views were made at the store's answer for a repeat's tab, with the key still down")
            }
            switch end {
            case .keyUp: Self.send(try Self.event(.keyUp, in: window), services)
            case .commandUp: Self.send(try Self.event(.flagsChanged, code: 55, flags: [], in: window), services)
            case .anotherKey: Self.send(try Self.event(.keyDown, code: Self.keyA, flags: [], in: window), services)
            case .repeatOfAnotherKey: Self.send(try Self.event(.keyDown, code: Self.keyA, repeats: true, flags: [], in: window), services)
            case .appResignsActive: Self.resignActive(services)
            }
            await Self.expectOnePageForTheSelectedTab(after: held, "the end \(end.rawValue), answer \(order.rawValue)", in: pane, services, built)
            guard order == .afterTheEnd else { return }
            // The daemon runs again: the store answers now, and its key takes the page that the end made.
            #expect(kill(daemon, SIGCONT) == 0, "fixture: the daemon's process did not run again")
            stopped = false
            let real = await answer.value()
            for _ in 0..<3 { await NewTabPageAtItsFrameTests.frame(services) }
            #expect(built() == held + 1, "\(built() - held - 1) page views more were made at the store's answer after the end \(end.rawValue)")
            let last = Self.state(of: pane, services)
            #expect(tabs.existingView(real) != nil, "the store's tab \(real) has no page view after the end \(end.rawValue); the pane: \(last)")
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
            let first = Self.state(of: pane, services)
            #expect(built() <= held + 1,
                    "\(built() - held) page views were made at the first frame after Command went up; the pane then: \(first)")
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

    /// A person lets go of another key while the New Tab key is down (a key that was down before). That key-up is
    /// no end of the hold, and each repeat after it is newer than it: the hold stays on, the repeats make no page,
    /// and the end makes one page, as with no other key.
    @Test func aKeyUpOfAnotherKeyInAHoldKeepsItForTheNextRepeats() async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-repeat-key-other-up") { services, window, pane, built in
            let hold = services.inputDispatch.newTabHold
            let held = try await Self.heldNewTabKey(repeats: 2, in: pane, window, services, built)
            Self.send(try Self.event(.keyUp, code: Self.keyA, flags: .command, in: window), services)
            #expect(hold.isOn, "the key-up of another key ended the hold")
            for _ in 0..<2 {
                try Self.newTabKey(repeats: true, in: pane, window, services)
                #expect(hold.isOn, "the hold is off after a repeat that came after the key-up of another key")
                await NewTabPageAtItsFrameTests.frame(services)
            }
            #expect(built() == held, "\(built() - held) page views were made for the repeats after the key-up of another key, with the key still down")
            Self.send(try Self.event(.keyUp, in: window), services)
            await Self.expectOnePageForTheSelectedTab(after: held, "the key-up, after the key-up of another key", in: pane, services, built)
        }
    }

    /// A close key ends a hold. A person holds the New Tab key and presses the close key with it still down. That
    /// key-down is no repeat: it ends the hold before its action runs. The close then runs on the tab that the pane
    /// has selected, the tab of the last repeat. After it the pane shows the tab that it has selected then, with a
    /// page view: no pane with an empty page, and one page view more at most.
    ///
    /// The test owns the order: the store answered the last open before the close key, and one frame ran between.
    /// Which tab the close selects is the close rule's, and no claim of this test. The test runs the close action
    /// in the key's dispatch, as the other tests here run the open: the key's way through the key router is not in
    /// this test.
    @Test func aCloseKeyEndsAHoldAndThePaneShowsThePageOfItsSelectedTab() async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-repeat-key-close") { services, window, pane, built in
            let hold = services.inputDispatch.newTabHold
            let tabs = services.agentTabs
            let answer = StoreAnswer()
            let held = try await Self.heldNewTabKey(repeats: 3, in: pane, window, services, lastAnswered: { answer.came($0) }, built)
            let newest = await answer.value()
            try #require(!ProvisionalTab.isProvisional(newest) && tabs.isNewTabPage(newest),
                         "fixture: the store's answer \(newest) is no New Tab page with a key of the store")
            await NewTabPageAtItsFrameTests.frame(services)
            // The tab that the close key acts on: the pane's selected tab, the last tab of the strip. The strip can
            // still name it by the key that it had before the store's answer.
            let closing: String = try #require(pane.stripModel.selectedID?.rawValue, "fixture: the pane has no selected tab")
            try #require(tabs.isNewTabPage(closing) && pane.orderedIDs.last?.rawValue == closing,
                         "fixture: the pane's selected tab is not the tab of the last repeat: \(Self.state(of: pane, services))")
            try #require(hold.isOn, "fixture: the 3 repeats began no hold")
            #expect(built() == held, "\(built() - held) page views were made for the tabs of 3 repeats, with the key still down")

            // The close key: a key-down of W with Command, and no repeat.
            var holdInTheCloseKeysTurn: Bool = true
            var ran: Bool = false
            Self.send(try Self.event(.keyDown, code: Self.keyW, in: window), services) {
                holdInTheCloseKeysTurn = hold.isOn
                ran = services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
            }
            #expect(!holdInTheCloseKeysTurn, "the hold was still on when the close key's action ran")
            #expect(ran, "the close action did not run")
            #expect(built() == held, "\(built() - held) page views were made in the close key's own turn, before a frame")

            await NewTabPageAtItsFrameTests.frame(services)
            let first: String = Self.state(of: pane, services)
            let stripKeys: [String] = pane.orderedIDs.map(\.rawValue)
            let gone: Bool = !stripKeys.contains(newest) && !stripKeys.contains(closing)
            #expect(gone,
                    "the tab of the last repeat (\(closing), the store's key \(newest)) is in the strip one frame after the close key; the pane: \(first)")
            for _ in 0..<3 { await NewTabPageAtItsFrameTests.frame(services) }
            let last: String = Self.state(of: pane, services)
            let selected: String? = pane.stripModel.selectedID?.rawValue
            let movedOn: Bool = selected != nil && selected != newest && selected != closing
            #expect(movedOn, "the pane has no other selected tab after the close key; the pane: \(last)")
            #expect(pane.currentTabKey == selected, "the pane does not show its selected tab after the close key; the pane: \(last)")
            let selectedHasItsPage: Bool = selected.map { !tabs.isNewTabPage($0) || tabs.existingView($0) != nil } ?? false
            #expect(selectedHasItsPage, "the selected tab is a New Tab page with no page view after the close key; the pane: \(last)")
            #expect(built() <= held + 1, "\(built() - held) page views were made after the close key; one at most is right, for the selected tab")
        }
    }

    /// A repeat that the app gets again after the key-up of its key. While the store has not answered a creation,
    /// the window keeps each key-down and lets the key-up through; at the answer it sends the kept key-downs again,
    /// as the events that the system made. A kept repeat that runs then is older than the key-up: no later event
    /// ends a hold that it begins, and the selected tab would have no page for the life of that hold.
    ///
    /// The rule (decision 2026-11-16): a repeat that is older than an event that ends a hold begins no hold. Its tab
    /// gets its page as the tab of a single key does, at the next frame.
    ///
    /// The two events have their times from the test, in the system's order (the repeat, then the key-up). NOT
    /// proven here: that the window sends a kept repeat again in this way (a read of `CreationInputCoordinator`).
    @Test func aRepeatDispatchedAgainAfterItsKeyUpBeginsNoHold() async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-repeat-key-late") { services, window, pane, built in
            let hold = services.inputDispatch.newTabHold
            let made: TimeInterval = ProcessInfo.processInfo.systemUptime
            let late = try Self.event(.keyDown, repeats: true, in: window, at: made - 2)
            let up = try Self.event(.keyUp, in: window, at: made - 1)
            // The app gets each of them once, in the system's order. The repeat opens nothing: the window keeps it.
            Self.send(late, services)
            Self.send(up, services)
            try #require(!hold.isOn, "fixture: a hold is on before the kept repeat runs")

            let before = built()
            Self.send(late, services) { NewTabPage.open(in: pane, seed: nil) }
            #expect(!hold.isOn, "a repeat that ran again after its key-up began a hold: no later event ends that hold")
            await Self.expectOnePageForTheSelectedTab(after: before, "a repeat that ran again after its key-up", in: pane, services, built)
        }
    }

    /// A repeat that the app gets again after the app is no longer the active app. A person holds the key and goes
    /// to another app: the key-up goes there. A kept repeat that runs after that is older than the resign: no later
    /// event ends a hold that it begins.
    ///
    /// The rule (decision 2026-11-16): a repeat that is no newer than the newest event that the app got before it
    /// resigned begins no hold. The resign has no time of its own, and no line reads a clock for it.
    @Test func aRepeatDispatchedAgainAfterTheAppResignedBeginsNoHold() async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-repeat-key-late-resign") { services, window, pane, built in
            let hold = services.inputDispatch.newTabHold
            let made: TimeInterval = ProcessInfo.processInfo.systemUptime
            let late = try Self.event(.keyDown, repeats: true, in: window, at: made - 1)
            // The app gets the repeat once before it resigns. The repeat opens nothing: the window keeps it.
            Self.send(late, services)
            Self.resignActive(services)
            try #require(!hold.isOn, "fixture: a hold is on before the kept repeat runs")

            let before = built()
            Self.send(late, services) { NewTabPage.open(in: pane, seed: nil) }
            #expect(!hold.isOn, "a repeat that ran again after the app resigned began a hold: no later event ends that hold")
            await Self.expectOnePageForTheSelectedTab(after: before, "a repeat that ran again after the app resigned", in: pane, services, built)
        }
    }

    /// Two panes. A hold is on, begun by a repeat in the first pane. A New Tab page then opens in the second pane
    /// with no event in dispatch (a command, not a key). The hold is the app's: the second pane makes no page for
    /// its tab while the key is down. The end of the hold must give EACH pane the page of its selected tab.
    ///
    /// The frame rule makes one new page view at a frame, so the two pages come at two frames: the test asks after
    /// the second frame. Where the keyboard is, and which pane's page comes first, are no claims of this test.
    ///
    /// The test owns the order: the store answered both opens before the end, and one frame ran between the second
    /// pane's open and the end. The wait for the second pane of the store has a deadline that fails the test, as
    /// the fixture's wait for the first pane has (`NewTabOpenFramesTests.focusedPane`); no claim of the rule waits
    /// that way.
    @Test func theEndOfAHoldGivesEachPaneThePageOfItsSelectedTab() async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-repeat-key-two-panes") { services, window, pane, built in
            let tabs = services.agentTabs
            let content = try #require(services.windows.active?.workspaceContent, "fixture: the window has no workspace content")
            // A second pane, with a terminal: its first tab is no New Tab page and makes no page view.
            var opensTerminal = ActionInvocation(origin: .user)
            opensTerminal.opensTerminal = true
            try #require(services.registry.perform("splitRight", invocation: opensTerminal), "fixture: the split did not run")
            @MainActor func second() -> PaneController? {
                content.panes.values.first { $0 !== pane && !ProvisionalPane.isStandIn($0.pane.handle) }
            }
            try await PasswordManagerRouteTests.until({ second() != nil }, within: .seconds(30), report: { "waiting for the split's pane of the store" })
            let other = try #require(second(), "fixture: no second pane of the store")
            try #require(content.panes.values.contains { $0 === pane }, "fixture: the first pane is no pane of the window after the split")

            let firstAnswer = StoreAnswer(), secondAnswer = StoreAnswer()
            let held = try await Self.heldNewTabKey(repeats: 3, in: pane, window, services, lastAnswered: { firstAnswer.came($0) }, built)
            #expect(built() == held, "\(built() - held) page views were made for the tabs of 3 repeats, with the key still down")
            try #require(services.inputDispatch.newTabHold.isOn, "fixture: the 3 repeats began no hold")
            _ = await firstAnswer.value()

            // A New Tab page opens in the second pane, with no event in dispatch.
            let secondCame: @MainActor (String) -> Void = { secondAnswer.came($0) }
            NewTabPage.open(in: other, seed: nil, then: secondCame)
            let real = await secondAnswer.value()
            try #require(!ProvisionalTab.isProvisional(real) && tabs.isNewTabPage(real),
                         "fixture: the store's answer \(real) is no New Tab page with a key of the store")
            await NewTabPageAtItsFrameTests.frame(services)
            let chosen = other.stripModel.selectedID?.rawValue
            try #require(chosen.map { tabs.isNewTabPage($0) } == true,
                         "fixture: the second pane's selected tab is no New Tab page: \(Self.state(of: other, services))")
            #expect(built() == held, "\(built() - held) page views were made for the second pane's tab, with the key still down")

            Self.send(try Self.event(.keyUp, in: window), services)
            #expect(built() == held, "\(built() - held) page views were made in the key-up's own turn, before a frame")
            for _ in 0..<2 { await NewTabPageAtItsFrameTests.frame(services) }
            let panes: String = "first pane: \(Self.state(of: pane, services)); second pane: \(Self.state(of: other, services))"
            #expect(built() == held + 2,
                    "\(built() - held) page views were made by the second frame after the key-up; two are right, one for each pane; \(panes)")
            for _ in 0..<2 { await NewTabPageAtItsFrameTests.frame(services) }
            #expect(built() == held + 2, "\(built() - held) page views were made by the fourth frame after the key-up; two are right")
            for (name, each) in [("first", pane), ("second", other)] {
                let selected = each.stripModel.selectedID?.rawValue
                #expect(each.currentTabKey == selected, "the \(name) pane does not show its selected tab after the key-up")
                #expect(selected.map { tabs.existingView($0) != nil } == true, "the \(name) pane's selected tab has no page view after the key-up")
            }
        }
    }
}
