@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Testing

/// Every stall says whether our code blocked the main thread, the Mac starved it of CPU, or it
/// sat in an idle wait (cmuxterm-hq#8504: the Dock flagged an idle NIGHTLY on a Mac at load 205).
struct StallVerdictTests {
    private let overloaded = HostLoad(one: 205, five: 172, fifteen: 144, cores: 10)
    private let calm = HostLoad(one: 2.5, five: 3, fifteen: 3, cores: 10)

    @Test func mainThreadCPUOverTheStallIsBlockedEvenOnALoadedMac() {
        #expect(StallVerdict.classify(wall: .seconds(3), mainThreadCPU: .milliseconds(2_800), host: overloaded) == .blocked)
        #expect(StallVerdict.classify(wall: .seconds(3), mainThreadCPU: .milliseconds(2_800), host: calm) == .blocked)
    }

    @Test func littleCPUOnACalmMacIsBlockedInASyscallOrLock() {
        #expect(StallVerdict.classify(wall: .seconds(3), mainThreadCPU: .milliseconds(20), host: calm) == .blocked)
    }

    @Test func littleCPUOnAnOverloadedMacIsStarved() {
        #expect(StallVerdict.classify(wall: .seconds(3), mainThreadCPU: .milliseconds(20), host: overloaded) == .starved)
        // Unknown CPU or load proves nothing: blocked, the conservative verdict.
        #expect(StallVerdict.classify(wall: .seconds(3), mainThreadCPU: nil, host: overloaded) == .blocked)
        #expect(StallVerdict.classify(wall: .seconds(3), mainThreadCPU: .milliseconds(20), host: nil) == .blocked)
    }

    @Test func aNestedRunLoopIsAnIdleWait() {
        #expect(StallVerdict.classify(wall: .seconds(3), mainThreadCPU: .milliseconds(5), host: overloaded, idleWait: true) == .waiting)
        #expect(StallVerdict.classify(wall: .seconds(3), mainThreadCPU: nil, host: calm, idleWait: true) == .waiting)
    }

    @Test func theHangFileNamesTheVerdictAndTheHostLoad() {
        let lines = HangLoad(mainThreadCPU: .milliseconds(30), host: overloaded).lines(duration: .seconds(3))
        #expect(lines.first?.hasPrefix("verdict: starved") == true)
        #expect(lines.contains("host load: 205.0 / 172.0 / 144.0 on 10 cores (overloaded)"))
        #expect(HangLoad(host: calm, idleWait: true).lines(duration: .seconds(3)).first?.hasPrefix("verdict: waiting") == true)
        #expect(HangLoad().lines(duration: .seconds(3)).contains("host load: unknown"))
    }

    @Test func theHostLoadIsReadable() {
        let host = HostLoad.current()
        #expect(host != nil)
        #expect((host?.cores ?? 0) > 0)
    }

    /// The case the heartbeat cannot see: the main thread is asleep in its event wait, so no
    /// stall runs, but the overloaded Mac takes seconds to run the probe's main-queue block.
    @Test func aSlowProbeAnswerOnAnOverloadedMacIsAStarvedRecord() throws {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangAssertThreshold: nil), uptime: clock.read)
        let directory = FileManager.default.temporaryDirectory.appending(path: "stall-verdict-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = HangEpisodeRecorder(directory: directory, symbolicate: { $0.map { String($0) } })
        watchdog.episodes = recorder

        // Under the hang threshold, or blocked (CPU used), or on a calm Mac: not this probe's record.
        #expect(watchdog.noteProbeAnswered(sentAt: 1, delayNanos: 1_000_000_000, cpuNanos: 0, host: overloaded) == nil)
        #expect(watchdog.noteProbeAnswered(sentAt: 1, delayNanos: 3_000_000_000, cpuNanos: 2_900_000_000, host: overloaded) == nil)
        #expect(watchdog.noteProbeAnswered(sentAt: 1, delayNanos: 3_000_000_000, cpuNanos: 1_000_000, host: calm) == nil)

        let record = try #require(watchdog.noteProbeAnswered(sentAt: 1, delayNanos: 3_000_000_000, cpuNanos: 1_000_000, host: overloaded))
        #expect(record.details["verdict"] == JSONValue.string("starved"))
        #expect(record.duration == .seconds(3))
        #expect(watchdog.log.records().count == 1)
        recorder.drain()
        let text = try String(contentsOf: try #require(recorder.entries.first?.url), encoding: .utf8)
        #expect(text.contains("verdict: starved"))
        #expect(text.contains("state: recovered"))

        // A hang the watchdog already reported in that window keeps its own record.
        watchdog.lastHangUptime.store(10, ordering: .releasing)
        #expect(watchdog.noteProbeAnswered(sentAt: 5, delayNanos: 3_000_000_000, cpuNanos: 0, host: overloaded) == nil)
    }
}
