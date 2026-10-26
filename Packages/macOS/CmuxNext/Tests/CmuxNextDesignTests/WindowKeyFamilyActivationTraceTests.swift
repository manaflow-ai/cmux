import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// `switch.app_activation` (p09-observability 039, perf-hot `cmd-tab`): each window's key tracker turns the
/// first key or activation notice of a turn into one async slice (AB, arg0 the notice's code) that the
/// Core Animation commit after the tracker's check ends (AE with the commit's outcome). A Cmd-Tab back
/// touches every window that has a material view once, however many notices it posts; the tracker's
/// first read is not a key change and writes nothing.
@MainActor @Suite(.serialized)
struct WindowKeyFamilyActivationTraceTests {
    /// The keyboard, a runtime with only the `switch` category on that keeps its records, and the commit
    /// boundaries the trackers asked for.
    @MainActor
    final class Harness {
        let keyboard = WindowKeyFamilyTrackerTests.Keyboard()
        let log = ActivationRecordLog()
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
    }

    private static let activation = SignpostName.switchAppActivation.rawValue

    @Test func theTrackersFirstReadWritesNoInterval() {
        let harness = Harness()
        let (window, family, _) = harness.window()
        defer { withExtendedLifetime(window) {} }
        harness.keyboard.post([])
        harness.commit()
        #expect(family.checks == 1)
        #expect(harness.log.records.isEmpty, "adding the first view reads the keyboard; it is not a key change")
        #expect(harness.boundaries.isEmpty)
    }

    @Test func aCmdTabBackIsOneAsyncSlicePerWindowEndedAtTheCommitAfterTheCheck() throws {
        let harness = Harness()
        let (first, _, _) = harness.window()
        let (second, _, _) = harness.window()
        defer { withExtendedLifetime(second) {} }
        harness.keyboard.post([])
        harness.commit()
        harness.keyboard.active = false
        harness.keyboard.post(NSApplication.didResignActiveNotification)
        harness.commit()
        harness.log.removeAll()

        harness.keyboard.active = true
        harness.keyboard.key = first
        // Becoming active posts several notices in one turn: one check and one slice per window.
        let checks = harness.keyboard.post([NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification,
                                            NSWindow.didBecomeMainNotification])
        #expect(checks == 2)
        let begins = harness.log.records.filter { $0.phase == .asyncBegin }
        #expect(begins.count == 2, "one AB per window the key change touched")
        #expect(begins.allSatisfy { $0.name == Self.activation })
        #expect(begins.allSatisfy { $0.arg0 == 5 },
                "arg0 is the turn's first notice: the app did become active")
        #expect(!harness.log.records.contains { $0.phase == .asyncEnd }, "the AE waits for the commit after the check")

        harness.commit()
        let ends = harness.log.records.filter { $0.phase == .asyncEnd }
        try #require(ends.count == 2)
        #expect(ends.allSatisfy { $0.name == Self.activation && $0.arg0 == 0 }, "a committed boundary ends it as committed")
        #expect(Set(begins.map(\.arg1)) == Set(ends.map(\.arg1)), "the async ids pair each AB with its AE")
        #expect(Set(begins.map(\.arg1)).count == 2, "each window's slice has its own async id")
    }

    @Test func aMissedCommitEndsTheSliceAsMissed() throws {
        let harness = Harness()
        let (window, _, _) = harness.window()
        harness.keyboard.post([])
        harness.keyboard.key = window
        harness.keyboard.post(NSWindow.didBecomeKeyNotification)
        harness.commit(.missed)
        let phases = harness.log.records.map(\.phase)
        #expect(phases == [.asyncBegin, .asyncEnd])
        let end = try #require(harness.log.records.last)
        #expect(end.arg0 == 1, "a missed boundary ends it as missed, so readers drop it")
        #expect(harness.log.records.first?.arg0 == 1, "a window did become key")
    }

    @Test func aSliceBegunBeforeTheLastViewLeftStillEnds() {
        let harness = Harness()
        let (window, family, view) = harness.window()
        defer { withExtendedLifetime(window) {} }
        harness.keyboard.post([])
        harness.keyboard.center.post(name: NSWindow.didResignKeyNotification, object: nil)
        view.removeFromSuperview()
        #expect(!family.isObserving)
        // The check runs on the next turn with nothing to observe; the slice still ends.
        harness.keyboard.post([])
        harness.commit()
        #expect(harness.log.records.map(\.phase) == [.asyncBegin, .asyncEnd])
    }
}

/// The records a test's runtime wrote.
nonisolated final class ActivationRecordLog: Sendable {
    private let state = Mutex<[TraceRuntime.StubRecord]>([])

    func append(_ record: TraceRuntime.StubRecord) { state.withLock { $0.append(record) } }

    func removeAll() { state.withLock { $0.removeAll() } }

    var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }
}
