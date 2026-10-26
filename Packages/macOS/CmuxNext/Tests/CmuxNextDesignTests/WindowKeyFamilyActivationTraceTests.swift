import AppKit
@testable import CmuxNextDesign
import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// `switch.app_activation` (p09-observability 039, perf-hot `cmd-tab`): a window's key tracker times a turn of key or
/// activation notices only where it flips the window's look (its inactive wash on or off). The flip begins one async
/// slice (AB: arg0 the turn's first notice in bits 0-7, bit 8 for a turn with the app's activation notice, the notice's
/// age in the top 24 bits) that the Core Animation commit after it ends (AE with the commit's outcome). A window whose
/// look stays writes nothing, so a Cmd-Tab back is one slice however many windows the app has, and the tracker's first
/// read is not a key change.
@MainActor @Suite(.serialized)
struct WindowKeyFamilyActivationTraceTests {
    /// The keyboard, a runtime with only the `switch` category on that keeps its records, and the commit
    /// boundaries the trackers asked for.
    @MainActor
    final class Harness {
        let keyboard = WindowKeyFamilyTrackerTests.Keyboard()
        let log = TraceRecordLog()
        let runtime: TraceRuntime
        var boundaries: [@MainActor (CommitBoundary.Outcome) -> Void] = []

        init() {
            let log = log
            runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
            runtime.setCategoryMask(1 << UInt64(SignpostCategory.switch.traceBit))
        }

        var environment: WindowKeyEnvironment {
            var environment = keyboard.environment
            environment.switchSignposter = Signposter(category: .switch, trace: runtime)
            environment.afterCommit = { [unowned self] body in self.boundaries.append(body) }
            return environment
        }

        /// Fires the boundaries asked for so far with `outcome` (the turn's commit).
        func commit(_ outcome: CommitBoundary.Outcome = .committed) {
            let pending = boundaries
            boundaries.removeAll()
            for body in pending { body(outcome) }
        }

        /// Posts `names` in one turn, runs their checks and fires the commit after them.
        func turn(_ names: [Notification.Name], _ outcome: CommitBoundary.Outcome = .committed) {
            keyboard.post(names)
            commit(outcome)
        }

        /// A window with one material view (it joins the window's tracker, made here with this harness's environment).
        func window() -> (NSWindow, WindowKeyFamily, WindowMaterialView) {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let family = WindowKeyFamily.of(window, environment: environment)
            let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
            window.contentView?.addSubview(view)
            return (window, family, view)
        }

        /// Makes `window` key in the active app (its tracker then knows its family held the keyboard).
        func makeKey(_ window: NSWindow?) {
            keyboard.key = window
            turn([NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification])
        }

        func records(_ phase: TraceRuntime.Phase) -> [TraceRuntime.StubRecord] {
            log.records.filter { $0.phase == phase && $0.name == SignpostName.switchAppActivation.rawValue }
        }
    }

    /// The fields of a `switch.app_activation` begin's `arg0`.
    private static func notice(_ record: TraceRuntime.StubRecord) -> (code: UInt64, appActivation: Bool, ageBits: UInt64) {
        (record.arg0 & 0xFF, record.arg0 >> 8 & 1 == 1, record.arg0 >> 40)
    }

    @Test func theTrackersFirstReadWritesNoInterval() {
        let harness = Harness()
        let (window, family, _) = harness.window()
        defer { withExtendedLifetime(window) {} }
        harness.turn([])
        #expect(family.checks == 1)
        #expect(harness.log.records.isEmpty, "adding the first view reads the keyboard; it is not a key change")
        #expect(harness.boundaries.isEmpty)
    }

    @Test func aCmdTabBackIsOneSliceForTheWindowWhoseWashGoesAway() throws {
        let harness = Harness()
        let (first, _, _) = harness.window()
        let (second, _, _) = harness.window()
        let (third, _, _) = harness.window()
        defer { withExtendedLifetime((first, second, third)) {} }
        harness.turn([])
        harness.makeKey(first)
        harness.makeKey(second)
        harness.keyboard.active = false
        harness.keyboard.key = nil
        harness.turn([NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
                      NSApplication.didResignActiveNotification])
        harness.log.removeAll()

        harness.keyboard.active = true
        harness.keyboard.key = second
        // Becoming active posts several notices in one turn: one check per window, a slice only where the wash goes.
        let checks = harness.keyboard.post([NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification,
                                            NSWindow.didBecomeMainNotification])
        #expect(checks == 3)
        let begins = harness.records(.asyncBegin)
        try #require(begins.count == 1, "only the window whose look flipped times the Cmd-Tab; its siblings stay inactive")
        let notice = Self.notice(begins[0])
        #expect(notice.code == 5, "arg0 holds the turn's first notice: the app did become active")
        #expect(notice.appActivation, "the turn had the app's activation notice")
        #expect(notice.ageBits != 0xFF_FFFF, "the begin holds the notice's age")
        #expect(harness.records(.asyncEnd).isEmpty, "the AE waits for the commit after the flip")

        harness.commit()
        let ends = harness.records(.asyncEnd)
        try #require(ends.count == 1)
        #expect(ends[0].arg0 == 0, "a committed boundary ends it as committed")
        #expect(ends[0].arg1 == begins[0].arg1, "the async id pairs the AB with its AE")
    }

    @Test func aFocusMoveInTheAppTimesOnlyTheWindowsThatFlipAndSaysItIsNoActivation() throws {
        let harness = Harness()
        let (first, _, _) = harness.window()
        let (second, _, _) = harness.window()
        defer { withExtendedLifetime((first, second)) {} }
        harness.turn([])
        harness.makeKey(first)
        harness.makeKey(second)
        #expect(harness.records(.asyncBegin).count == 1, "first's wash came on; second never looked inactive")
        harness.log.removeAll()

        harness.makeKey(first)
        let begins = harness.records(.asyncBegin)
        try #require(begins.count == 2, "first's wash went away and second's came on")
        #expect(begins.allSatisfy { Self.notice($0).code == 2 }, "the turn's first notice: a window did resign key")
        #expect(begins.allSatisfy { !Self.notice($0).appActivation }, "no app activation notice in the turn")
        #expect(Set(begins.map(\.arg1)).count == 2, "each window's slice has its own async id")
        #expect(harness.records(.asyncEnd).count == 2)
    }

    @Test func aKeyChangeNoWindowShowsWritesNothing() {
        let harness = Harness()
        let (first, _, _) = harness.window()
        let (second, _, _) = harness.window()
        defer { withExtendedLifetime((first, second)) {} }
        harness.turn([])
        harness.makeKey(first)
        harness.log.removeAll()
        // A panel of the same family or a page window becoming key and going again: no window's look changes.
        harness.turn([NSWindow.didBecomeKeyNotification])
        harness.turn([NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification])
        #expect(harness.log.records.isEmpty, "two windows, two turns, no flip: no slice")
        #expect(harness.boundaries.isEmpty)
    }

    @Test func aMissedCommitEndsTheSliceAsMissed() throws {
        let harness = Harness()
        let (window, _, _) = harness.window()
        defer { withExtendedLifetime(window) {} }
        harness.turn([])
        harness.makeKey(window)
        harness.keyboard.key = nil
        harness.turn([NSWindow.didResignKeyNotification], .missed)
        #expect(harness.log.phases == [.asyncBegin, .asyncEnd])
        let begin = try #require(harness.log.records.first)
        #expect(Self.notice(begin).code == 2, "a window did resign key")
        let end = try #require(harness.log.records.last)
        #expect(end.arg0 == 1, "a missed boundary ends it as missed, so readers drop it")
    }

    @Test func aNoticeWhoseCheckFindsNoViewWritesNothing() {
        let harness = Harness()
        let (window, family, view) = harness.window()
        defer { withExtendedLifetime(window) {} }
        harness.turn([])
        harness.makeKey(window)
        harness.keyboard.key = nil
        harness.keyboard.center.post(name: NSWindow.didResignKeyNotification, object: nil)
        view.removeFromSuperview()
        #expect(!family.isObserving)
        // The check runs on the next turn with nothing to observe: it decides nothing, so it times nothing.
        harness.turn([])
        #expect(harness.log.records.isEmpty)
        #expect(harness.boundaries.isEmpty)
    }
}
