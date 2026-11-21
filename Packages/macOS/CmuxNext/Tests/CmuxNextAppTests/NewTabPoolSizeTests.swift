import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextFocusUI
import CmuxNextTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The pool kept one prewarmed page whatever the opens did, so of three chats opened one after the other only the
/// first found a page: the next two each built a page of their own and ran every wait of a cold open. The pool's size
/// is a rule now (decision 2026-11-16): as many pages as the opens of the last second asked for, 3 at most; 60 s with
/// no open puts the pool back to one page, and so does memory pressure.
///
/// The pages are inert (each counts as loaded, drawn and connected to acpmux). The refill's wait and the 60 s run on a
/// clock the test moves; the frames are the app's own.
///
/// No test polls: each waits for the moment a timer sleeps on that clock, and for the pool's own events (a page was
/// made, the refiller's counts changed). A limit on the wall clock only ends a test that fails.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabPoolSizeTests {
    /// The app's pool with inert pages, its refills on a clock the test moves, and input that never goes quiet.
    @MainActor final class Fixture {
        let services: AppServices
        let window: NSWindow
        let clock = ManualClock()
        let rig = NewTabRapidPairTests.Rig()
        /// What the pool did (a page was made, the refiller's counts changed), as events a test waits for.
        let events = ChatSpareRefillTests.Events()
        /// Pages made while an input event was in dispatch, and pages made inside an open's own dispatch. The rule is 0.
        var madeInInput = 0
        private var opened = 0

        var pool: NewTabSparePool { services.newTabSpares }

        init(_ services: AppServices, window: NSWindow) {
            self.services = services
            self.window = window
        }

        /// An inert page that stands in for a real one.
        func page(_ newTab: AgentPaneNewTab, html: URL) -> AgentPaneView? {
            let model = AgentPaneModel(host: services.agentTabs.host, newTab: newTab)
            guard let view = AgentPaneView(model: model, source: .bundled(html)) else { return nil }
            model.hasHandshake = true
            model.markPainted()
            model.clientReady = true
            if services.inputDispatch.event != nil { madeInInput += 1 }
            rig.made.append(view)
            events.note()
            return view
        }

        /// Three chats opened one after the other, each inside a key's dispatch as the app opens it: 10 ms apart on
        /// the pool's clock, with a frame commit between them. A page that was handed out switches to its chat and
        /// draws it. Nil for an open that found no connected page.
        func burst() async throws -> [AgentPaneView?] {
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, characters: "j",
                                                    charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
            var pages: [AgentPaneView?] = []
            for _ in 0..<3 {
                let made = rig.made.count
                let page = services.inputDispatch.dispatching(key) { services.agentTabs.takeConnectedSpare?() }
                #expect(rig.made.count == made, "a page was made in the key's turn of an open")
                if let page {
                    opened += 1
                    try #require(page.model.adoptSpareSession("s-pool-size-\(opened)"), "the page refused the chat: \(page.model.spareRefusal)")
                    page.model.markPainted()
                }
                pages.append(page)
                clock.advance(by: .milliseconds(10))
                await Self.frameCommit()
            }
            return pages
        }

        /// The refill's wait of the last handout is asleep on the pool's clock (the release's 60 s sleep there too,
        /// and are due much later), then it passes: the pages come at the app's frames until the pool holds `count`.
        func fills(to count: Int, _ what: String) async throws {
            try await clock.waitForSleeper(dueBy: clock.now.advanced(by: AgentPaneSpareRefiller.settle))
            clock.advance(by: AgentPaneSpareRefiller.settle)
            try await events.wait(until: { pool.spares.count >= count }, report: {
                "\(what); \(pool.refills.counts); \(NewTabRapidPairTests.poolState(services, rig))"
            })
            #expect(pool.spares.count == count, "the pool holds \(pool.spares.count) pages, the rule gives \(count)")
        }

        /// This run-loop pass committed its frame.
        static func frameCommit() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in AfterFrameCommit().run { done.resume() } }
        }
    }

    /// The app with one inert page parked, on a fresh daemon. From there on the person's input never goes quiet (the
    /// pool's own quiet-input warm never comes), and the refills run on the fixture's clock.
    static func withPool(_ id: String, _ body: (Fixture) async throws -> Void) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: id)
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, _) = try await NewTabOpenFramesTests.focusedPane(services)
            let folder = try NewTabRapidPairTests.folder()
            let fixture = Fixture(services, window: window)
            defer { NewTabRapidPairTests.cleanUp(services, fixture.rig, folder) }
            let html = folder.appending(path: "index.html")
            try Data("<html><body>New Tab spare fixture</body></html>".utf8).write(to: html)
            let pool = services.newTabSpares
            pool.dropAll()
            pool.makeSpare = { [unowned fixture] page in fixture.page(page, html: html) }
            pool.refills.onCounts = { [events = fixture.events] _ in events.note() }
            defer { pool.refills.onCounts = nil }
            pool.retarget(window)
            pool.prewarm()
            pool.start()
            // The pool parks a page in the turn that made it, so the wait's own turn finds it parked.
            try await fixture.events.wait(until: { fixture.rig.made.count == 1 && pool.spare != nil }, report: {
                "no page at the start; \(NewTabRapidPairTests.poolState(services, fixture.rig))"
            })
            // A Mac in Low Power Mode or at a serious thermal state hands no page to a chat (AgentPaneSpareReadiness).
            // The inert page is loaded, drawn and connected, so only the Mac's state can refuse it: the test stops
            // here with that reason, and such a red is not read as a fault of the size rule.
            let parked = try #require(pool.spare?.view)
            try #require(parked.model.servesExistingChat, """
                this Mac is in Low Power Mode or hot (thermal state \(ProcessInfo.processInfo.thermalState.rawValue)): \
                the pool hands no page to a chat here, so this run says nothing about the size rule
                """)
            pool.idleInput = .seconds(3600)
            pool.refills.clock = fixture.clock
            try await body(fixture)
        }
    }

    /// Three opens with a frame between each, three times, while input never goes quiet: the first burst finds the
    /// one page of an idle pool, and by the third burst every open finds a warm page. No page is made in a key's turn.
    @Test func byTheThirdBurstOfThreeOpensEveryOpenFindsAWarmPage() async throws {
        try await Self.withPool("cn-pool-size-burst") { fixture in
            let first = try await fixture.burst()
            #expect(first.map { $0 != nil } == [true, false, false], "an idle pool keeps one page: \(first.map { $0 != nil })")
            try await fixture.fills(to: 3, "no 3 pages followed the first burst")

            let second = try await fixture.burst()
            #expect(second.allSatisfy({ $0 != nil }), "not every open of the second burst found a page: \(second.map { $0 != nil })")
            try await fixture.fills(to: 3, "no 3 pages followed the second burst")

            let third = try await fixture.burst().compactMap { $0 }
            #expect(third.count == 3, "\(third.count) of the third burst's 3 opens found a warm page")
            #expect(Set(third.map(ObjectIdentifier.init)).count == third.count, "two opens got the same page")
            #expect(fixture.madeInInput == 0, "\(fixture.madeInInput) pages were made while an input event was in dispatch")
        }
    }

    /// 60 s with no open: the pool is back to one page, the one the next open gets. One second before, it still
    /// holds three.
    @Test func sixtySecondsWithNoOpenPutThePoolBackToOnePage() async throws {
        try await Self.withPool("cn-pool-size-release") { fixture in
            let pool = fixture.pool, clock = fixture.clock
            _ = try await fixture.burst()
            let lastOpen = clock.now.offset - .milliseconds(10)
            try await fixture.fills(to: 3, "no 3 pages followed the burst")
            let next = try #require(pool.spare?.view), others = pool.spares.filter { $0 !== next }

            // The refill's wait ended, so the one timer asleep on the clock is the release. Its 60 s count from the
            // moment its timer went to sleep: at the last open, or some steps of the test's clock later.
            try await clock.waitForSleeper()
            #expect(clock.sleeperDeadlines.count == 1, "\(clock.sleeperDeadlines.count) timers sleep on the pool's clock after the refill")
            let due = try #require(clock.sleeperDeadlines.first).offset
            #expect(due >= lastOpen + AgentPaneSpareDemand.release && due <= clock.now.offset + AgentPaneSpareDemand.release,
                    "the release is due \(due - lastOpen) after the last open")

            clock.advance(by: due - .seconds(1) - clock.now.offset)
            for _ in 0..<5 { await Fixture.frameCommit() }
            #expect(pool.spares.count == 3, "the pool released pages \(clock.now.offset - lastOpen) after the last open")

            clock.advance(by: .seconds(1))
            try await fixture.events.wait(until: { pool.spares.count == 1 }, report: {
                "60 s after the last open; \(pool.refills.counts); \(NewTabRapidPairTests.poolState(fixture.services, fixture.rig))"
            })
            #expect(pool.capacity == 1, "the pool's size is \(pool.capacity) after the release")
            #expect(pool.spare?.view === next, "the release took the page the next open gets")
            #expect(others.allSatisfy({ $0.superview == nil }), "a released page stayed in the window")
            #expect(fixture.madeInInput == 0)
        }
    }

    /// Memory pressure drops the pages and the burst's count with them: back at normal the pool makes one page.
    @Test func memoryPressurePutsThePoolBackToOnePage() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-pool-size-pressure")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, _) = try await NewTabOpenFramesTests.focusedPane(services)
            let folder = try NewTabRapidPairTests.folder()
            let html = folder.appending(path: "index.html")
            try Data("<html><body>New Tab spare fixture</body></html>".utf8).write(to: html)
            // A pool of its own, on a pressure source the test drives (the app's pool reads the kernel's).
            let fixture = Fixture(services, window: window), source = ManualMemoryPressureSource()
            let pool = NewTabSparePool(services: services, memoryPressure: MemoryPressureEvents(source: source))
            defer {
                pool.makeSpare = nil
                pool.refills.onCounts = nil
                pool.dropAll()
                fixture.rig.made.forEach { $0.close() }
                try? FileManager.default.removeItem(at: folder)
            }
            pool.makeSpare = { [unowned fixture] page in fixture.page(page, html: html) }
            pool.refills.onCounts = { [events = fixture.events] _ in events.note() }
            pool.idleInput = .milliseconds(50)
            pool.retarget(window)
            pool.prewarm()
            // The pool parks a page in the turn that made it, so the wait's own turn finds it parked.
            try await fixture.events.wait(until: { pool.spares.count == 1 }, report: { "no page at the start" })

            // Three Cmd-T in one second: each key asks the pool.
            let size = NSSize(width: 640, height: 480)
            let taken = (0..<3).map { _ in pool.take(for: window, size: size)?.view }
            #expect(taken.map { $0 != nil } == [true, false, false])
            try await fixture.events.wait(until: { pool.spares.count == 3 }, report: {
                "no 3 pages followed the burst: \(pool.spares.count) pages, size \(pool.capacity); \(pool.refills.counts)"
            })

            source.send(.warning)
            #expect(pool.spares.isEmpty, "memory pressure kept \(pool.spares.count) pages")
            #expect(pool.capacity == 1, "memory pressure kept the burst's size: \(pool.capacity)")
            source.send(.normal)
            try await fixture.events.wait(until: { pool.spares.count == 1 }, report: { "no page after the pressure ended" })
            // A pool of size 1 that holds its page has no room: some more passes of the run loop make no page. (No
            // wait on the wall clock follows; the size is the fact that stops a second page.)
            for _ in 0..<5 { await Fixture.frameCommit() }
            #expect(pool.spares.count == 1 && pool.capacity == 1, "\(pool.spares.count) pages, size \(pool.capacity), after the pressure ended")
        }
    }
}
