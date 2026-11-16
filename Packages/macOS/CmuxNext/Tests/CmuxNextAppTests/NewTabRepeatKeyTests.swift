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
/// A single key is not a repeat: it starts no hold, and its page comes as before.
///
/// The events here are made in the test and go through the app's input dispatch context, the one place that gets
/// each event of `NSApplication.sendEvent`. That macOS hands the app each of these events for a real held Cmd-T is
/// NOT proven here. For the key-up of a key while Command is down, the proof is a read of a real app's input
/// journal (2026-11-16): key-ups with Command down came for shortcut letters; none of them was the T key.
///
/// Frames are the app's own, and a test waits for one by an event (`NewTabPageAtItsFrameTests.frame`). No wait
/// polls and no wait reads a clock.
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

    /// Frames until `built` is over `count`, 240 at most: the tab that the pane shows gets its page at the next
    /// frame, or at a later one when the launch still held it.
    private static func framesUntilMore(than count: Int, _ built: () -> Int, _ services: AppServices) async {
        for _ in 0..<240 where built() == count { await NewTabPageAtItsFrameTests.frame(services) }
    }

    /// A press and `repeats` repeats of the New Tab key, with a frame after each key. Returns the count of page
    /// views after the press's own page: the repeats must add none to it.
    private static func heldNewTabKey(repeats: Int, in pane: PaneController, _ window: NSWindow, _ services: AppServices,
                                      _ built: () -> Int) async throws -> Int {
        let tabs = services.agentTabs
        let start = built()
        try newTabKey(repeats: false, in: pane, window, services)
        await framesUntilMore(than: start, built, services)
        try #require(built() == start + 1, "the press of the key (no repeat) made \(built() - start) page views")
        let pages = Set(tabs.newTabPages.keys)
        for _ in 0..<repeats {
            try newTabKey(repeats: true, in: pane, window, services)
            await NewTabPageAtItsFrameTests.frame(services)
        }
        let opened = tabs.newTabPages.keys.filter { !pages.contains($0) }.count
        try #require(opened == repeats, "the \(repeats) repeats opened \(opened) New Tab pages")
        return start + 1
    }

    /// After the hold's end: one page view more, for the tab that the pane has selected, and no other one later.
    private static func expectOnePageForTheSelectedTab(after held: Int, _ why: String, in pane: PaneController, _ services: AppServices,
                                                       _ built: () -> Int) async {
        await framesUntilMore(than: held, built, services)
        for _ in 0..<3 { await NewTabPageAtItsFrameTests.frame(services) }
        #expect(built() == held + 1, "\(built() - held) page views were made after \(why); exactly one is right")
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
            try #require(built() == held, "\(built() - held) page views were made for the tabs of 3 repeats, with the key still down")
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

    /// A press with no repeat starts no hold: its page comes at a frame with no key-up, no flags event and no other
    /// key. So does the page of a second press (a system that hands the app no key-up delays nothing).
    @Test func aSingleNewTabKeyStartsNoHold() async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool("cn-repeat-key-single") { services, window, pane, built in
            for press in 1...2 {
                let before = built()
                try Self.newTabKey(repeats: false, in: pane, window, services)
                await Self.framesUntilMore(than: before, built, services)
                #expect(built() == before + 1, "press \(press) of the key (no repeat) made \(built() - before) page views with no end event")
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
            try #require(input.isHolding(in: window), "the last repeat began no key hold: \(input.log.suffix(4))")
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

    /// A repeat takes no page out of the pool: the parked page stays for the next press. The press then takes it in
    /// its own turn, as before.
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

            let single = built()
            try Self.newTabKey(repeats: false, in: pane, window, services)
            #expect(pool.spare?.view !== parked, "a press of the key (no repeat) did not take the parked page")
            #expect(built() == single + 1, "the press's tab got \(built() - single) page views in the key's own turn")
        }
    }
}
