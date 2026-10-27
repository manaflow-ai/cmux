import CmuxNextTrace
import CmuxNextWakeups
import CmuxSafeConcurrency
import Dispatch
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// What a test reads of one sent Sentry `Event` (a class that is not Sendable), copied in the capture.
private struct SentDump: Sendable {
    let level: SentryLevel
    let fingerprint: [String]?
    let tags: [String: String]
    let exceptionType: String?

    init(_ event: Event) {
        level = event.level
        fingerprint = event.fingerprint
        tags = event.tags ?? [:]
        exceptionType = event.exceptions?.first?.type
    }
}

/// A lane that holds its blocks until the test runs them, and the dumps their captures sent.
private final class HeldDumpLane: Sendable {
    private let blocks = CmuxSafeConcurrency.Mutex<[@Sendable () -> Void]>([])
    private let sent = CmuxSafeConcurrency.Mutex<[SentDump]>([])
    private let stackWalks = CmuxSafeConcurrency.Mutex(0)

    func sink(crashKeys: CrashKeySlots? = nil) -> InvariantSink {
        InvariantSink(sends: true, lane: { block in self.blocks.withLock { $0.append(block) } },
                      capture: { event in
                          let copy = SentDump(event)
                          self.sent.withLock { $0.append(copy) }
                      },
                      stack: { self.stackWalks.withLock { $0 += 1 }; return [] },
                      crashKeys: crashKeys)
    }

    var dumps: [SentDump] { sent.withLock { $0 } }
    var walks: Int { stackWalks.withLock { $0 } }

    func runHeld() {
        let run = blocks.withLock { blocks in
            let run = blocks
            blocks = []
            return run
        }
        for block in run { block() }
    }
}

/// A count threads share.
private final class Claims: Sendable {
    private let count = CmuxSafeConcurrency.Mutex(0)

    func add() { count.withLock { $0 += 1 } }

    var value: Int { count.withLock { $0 } }
}

/// p09-observability-130: `Invariant.dumpWithoutCrashing` at a Release invariant site sends one non-fatal event per
/// site per launch, with the stack and the crash keys as they were at the call.
@Suite struct DumpWithoutCrashingTests {
    @Test func aSiteDumpsOncePerLaunchHoweverOftenAndFromWhicheverThread() {
        let held = HeldDumpLane()
        let invariant = Invariant(capacity: 8)
        invariant.install(build: 10, sink: held.sink())
        let claims = Claims()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if Invariant.dumpWithoutCrashing("rate-limited", in: invariant) { claims.add() }
        }
        held.runHeld()
        #expect(claims.value == 1, "one call of the site reported")
        #expect(held.dumps.count == 1)
        #expect(held.walks == 1, "a repeat costs the caller no stack walk")
        Invariant.dumpWithoutCrashing("another-site", in: invariant)
        held.runHeld()
        #expect(held.dumps.count == 2, "another site reports on its own")
    }

    @Test func theDumpCarriesTheCrashKeysOfTheCallNotOfTheLane() {
        let held = HeldDumpLane()
        let keys = CrashKeySlots()
        let page = CrashKeyPage(identity: .init(role: .app))
        keys.page.attach(page)
        page.set(.windowCount, 4)
        let invariant = Invariant(capacity: 8)
        invariant.install(build: 10, sink: held.sink(crashKeys: keys))
        let action = CrashKeySlots.stableKey("workspace.new")
        let reported = keys.withKey(.actionID, action) {
            Invariant.dumpWithoutCrashing("keys-at-the-call", in: invariant)
        }
        #expect(reported)
        page.set(.windowCount, 8)
        held.runHeld() // after the action's scope put its key back and the window count moved
        let tags = held.dumps.first?.tags ?? [:]
        #expect(tags["crash_key.action_id"] == String(action, radix: 16))
        #expect(tags["crash_key.window_count"] == "4")
        #expect(tags["invariant_tier"] == "dump_without_crashing")
        #expect(tags["invariant_id"] == "keys-at-the-call")
    }

    @Test func withoutCrashKeysTheDumpHasNone() {
        let held = HeldDumpLane()
        let invariant = Invariant(capacity: 8)
        invariant.install(build: 10, sink: held.sink())
        Invariant.dumpWithoutCrashing("no-keys", in: invariant)
        held.runHeld()
        let tags = held.dumps.first?.tags ?? [:]
        #expect(!tags.isEmpty)
        #expect(tags.keys.allSatisfy { !$0.hasPrefix("crash_key.") })
    }

    @Test func theEventIsANonFatalDumpGroupedBySite() {
        let dump = InvariantEvent(kind: .dumpWithoutCrashing, id: "grouped", fileID: "Module/File.swift", line: 9)
        let event = SentDump(InvariantSink.event(for: dump, addresses: []))
        #expect(event.level == .warning)
        #expect(event.exceptionType == "DumpWithoutCrashing")
        #expect(event.fingerprint == ["invariant", "grouped", "Module/File.swift:9"])
        #expect(event.tags["invariant_tier"] == "dump_without_crashing")
        #expect(event.tags["invariant_fatal_build"] == nil)
    }

    @Test func pageKeysAndSlotKeysMergeIntoTags() {
        var slots = CrashKeySlots.Snapshot()
        slots.daemonEpoch = 3
        let page = CrashKeyPage(identity: .init(role: .app))
        page.set(.terminalCount, 2)
        let keys = InvariantCrashKeys(slots: slots, page: page.snapshot())
        #expect(keys.tags["crash_key.daemon_epoch"] == "3")
        #expect(keys.tags["crash_key.terminal_count"] == "2")
        #expect(InvariantCrashKeys(slots: CrashKeySlots.Snapshot(), page: nil).tags.isEmpty)
    }
}
