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

    /// A stall is judged by the most load seen while it ran: a NIGHTLY's 1517 s hang of
    /// 2026-11-27T01:25Z began at load 501.7 on 10 cores and ended at 6.9, and read as our code
    /// (cmuxterm-hq#8670) when only the end was read.
    @Test func aStallIsJudgedByItsPeakLoadNotItsEnd() {
        let storm = HostLoad(one: 501.7, five: 227.9, fifteen: 101.3, cores: 10)
        let after = HostLoad(one: 6.9, five: 11.3, fifteen: 44.4, cores: 10)
        #expect(HostLoad.peak(storm, after) == storm)
        #expect(HostLoad.peak(after, storm) == storm)
        #expect(HostLoad.peak(nil, after) == after)
        #expect(HostLoad.peak(after, nil) == after)
        #expect(HostLoad.peak(nil, nil) == nil)
        let wall = Duration.seconds(1517.574), cpu = Duration.milliseconds(8)
        #expect(StallVerdict.classify(wall: wall, mainThreadCPU: cpu, host: after) == .blocked)
        #expect(StallVerdict.classify(wall: wall, mainThreadCPU: cpu, host: HostLoad.peak(storm, after)) == .starved)
    }

    @Test func aNestedRunLoopIsAnIdleWait() {
        #expect(StallVerdict.classify(wall: .seconds(3), mainThreadCPU: .milliseconds(5), host: overloaded, idleWait: true) == .waiting)
        #expect(StallVerdict.classify(wall: .seconds(3), mainThreadCPU: nil, host: calm, idleWait: true) == .waiting)
    }

    /// Under each verdict, the thread state System Trace would show (WWDC26 268, hq#18524): a blocked
    /// main thread that ran is our own work; one off-core is a syscall wait. A starved one is our own
    /// queues when this process kept half the cores busy, else the host's load.
    @Test func eachVerdictSplitsIntoItsThreadState() {
        func cause(_ verdict: StallVerdict, cpu: Duration?, cores: Double?, host: HostLoad?) -> StallCause? {
            StallCause.classify(verdict: verdict, wall: .seconds(3), mainThreadCPU: cpu, processCores: cores, host: host)
        }
        #expect(cause(.blocked, cpu: .milliseconds(2_800), cores: nil, host: calm) == .ownWork)
        #expect(cause(.blocked, cpu: .milliseconds(1_500), cores: nil, host: calm) == .ownWork)
        #expect(cause(.blocked, cpu: .milliseconds(1_400), cores: nil, host: calm) == .syscallWait)
        #expect(cause(.blocked, cpu: .milliseconds(20), cores: 0.1, host: nil) == .syscallWait)
        #expect(cause(.blocked, cpu: nil, cores: 1, host: calm) == nil)
        #expect(cause(.starved, cpu: .milliseconds(20), cores: 0.4, host: overloaded) == .hostLoad)
        #expect(cause(.starved, cpu: .milliseconds(20), cores: 4.9, host: overloaded) == .hostLoad)
        #expect(cause(.starved, cpu: .milliseconds(20), cores: 5, host: overloaded) == .ownQueues)
        #expect(cause(.starved, cpu: .milliseconds(20), cores: nil, host: overloaded) == nil)
        #expect(cause(.waiting, cpu: .milliseconds(5), cores: 9, host: overloaded) == nil)
    }

    @Test func theHangFileNamesTheCause() {
        let ours = HangLoad(mainThreadCPU: .milliseconds(30), host: overloaded, processCores: 7.3).lines(duration: .seconds(3))
        #expect(ours[0].hasPrefix("verdict: starved"))
        #expect(ours[1].hasPrefix("cause: own-queues (") && ours[1].hasSuffix("; this process 7.3 cores)"))
        let theirs = HangLoad(mainThreadCPU: .milliseconds(30), host: overloaded, processCores: 0.3).lines(duration: .seconds(3))
        #expect(theirs[1].hasPrefix("cause: host-load ("))
        let syscall = HangLoad(mainThreadCPU: .milliseconds(30), host: calm).lines(duration: .seconds(3))
        #expect(syscall[1].hasPrefix("cause: syscall-wait ("))
        #expect(HangLoad(mainThreadCPU: .seconds(3), host: calm).lines(duration: .seconds(3))[1].hasPrefix("cause: own-work ("))
        #expect(HangLoad().lines(duration: .seconds(3))[1] == "cause: unknown")
        #expect(!HangLoad(host: calm, idleWait: true).lines(duration: .seconds(3)).contains { $0.hasPrefix("cause:") })
    }

    @Test func thisProcessesCPUReadsInCores() throws {
        let start = TaskEventCounts(faults: 0, pageIns: 0, processCPUNanos: 1_000_000_000, uptimeNanos: 10_000_000_000)
        let end = TaskEventCounts(faults: 0, pageIns: 0, processCPUNanos: 7_000_000_000, uptimeNanos: 12_000_000_000)
        #expect(start.processCores(to: end) == 3)
        #expect(start.processCores(to: nil) == nil)
        #expect(end.processCores(to: start) == nil)  // no time passed forward
        #expect(start.load(to: end, cpu: nil).processCores == 3)
        let now = try #require(TaskEventCounts.current())
        #expect(now.processCPUNanos != nil && now.uptimeNanos > 0)
    }

    @Test func theHangFileNamesTheVerdictAndTheHostLoad() {
        let lines = HangLoad(mainThreadCPU: .milliseconds(30), host: overloaded).lines(duration: .seconds(3))
        #expect(lines.first?.hasPrefix("verdict: starved") == true)
        #expect(lines.contains("host load: 205.0 / 172.0 / 144.0 on 10 cores (overloaded)"))
        #expect(HangLoad(host: calm, idleWait: true).lines(duration: .seconds(3)).first?.hasPrefix("verdict: waiting") == true)
        #expect(HangLoad().lines(duration: .seconds(3)).contains("host load: unknown"))
    }

    @Test func theHangFileNamesTheHostMemory() {
        let start = HostMemory(swapUsed: 1_900_000_000, compressedPages: 400_000, freePages: 5_000, pageIns: 100_000, pressureLevel: 1)
        let end = HostMemory(swapUsed: 2_080_000_000, compressedPages: 412_000, freePages: 3_100, pageIns: 109_400, pressureLevel: 2)
        let memory = HostMemoryDelta(from: start, to: end)
        #expect(memory.swapGrowth == 180_000_000)
        #expect(memory.pageIns == 9_400)
        let lines = HangLoad(mainThreadCPU: .milliseconds(30), pageIns: 3, host: overloaded, memory: memory).lines(duration: .seconds(3))
        #expect(lines.contains("host memory: swap 2.1 GB (+180.0 MB), compressed 412000, free 3100 pages, host page-ins 9400, pressure warning (pressured)"))
        #expect(HangLoad().lines(duration: .seconds(3)).contains("host memory: unknown"))
    }

    @Test func aCalmHostIsNotPressured() {
        let calmMemory = HostMemory(swapUsed: 0, compressedPages: 10_000, freePages: 90_000, pageIns: 500, pressureLevel: 1)
        let memory = HostMemoryDelta(from: calmMemory, to: calmMemory)
        #expect(!memory.isPressured(duration: .seconds(3), processPageIns: 2))
        // Swap shrinking is not pressure; its line says so without the mark.
        let shrank = HostMemoryDelta(now: calmMemory, swapGrowth: -50_000_000, pageIns: 0)
        #expect(shrank.line(duration: .seconds(3), processPageIns: nil)
            == "host memory: swap 0.0 MB (-50.0 MB), compressed 10000, free 90000 pages, host page-ins 0, pressure normal")
        // Each trigger alone marks it: this process's own page-ins, or the host paging fast.
        #expect(memory.isPressured(duration: .seconds(3), processPageIns: 50))
        let paging = HostMemoryDelta(now: calmMemory, swapGrowth: 0, pageIns: 6_000)
        #expect(paging.isPressured(duration: .seconds(3), processPageIns: nil))
        #expect(!paging.isPressured(duration: .seconds(4), processPageIns: nil))
    }

    @Test func theHostMemoryIsReadable() {
        let memory = HostMemory.current()
        #expect(memory != nil)
        #expect((memory?.freePages ?? 0) > 0)
    }

    @Test func theHostLoadIsReadable() {
        let host = HostLoad.current()
        #expect(host != nil)
        #expect((host?.cores ?? 0) > 0)
    }

    /// The case the heartbeat cannot see: the main thread is asleep in its event wait, so no
    /// stall runs, but the overloaded Mac takes seconds to run the probe's main-queue block.
    @Test @MainActor func aSlowProbeAnswerOnAnOverloadedMacIsAStarvedRecord() throws {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangAssertThreshold: nil), uptime: clock.read)
        let directory = FileManager.default.temporaryDirectory.appending(path: "stall-verdict-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = HangEpisodeRecorder(directory: directory, symbolicate: { $0.map { String($0) } })
        watchdog.episodes = recorder

        // Under the hang threshold, or blocked (CPU used), or on a calm Mac: not this probe's record.
        watchdog.noteProbeAnswered(sentAt: 1, delayNanos: 1_000_000_000, cpuNanos: 0, host: { [overloaded] in overloaded })
        watchdog.noteProbeAnswered(sentAt: 1, delayNanos: 3_000_000_000, cpuNanos: 2_900_000_000, host: { [overloaded] in overloaded })
        watchdog.noteProbeAnswered(sentAt: 1, delayNanos: 3_000_000_000, cpuNanos: 1_000_000, host: { [calm] in calm })
        watchdog.probeReportQueue.sync {}
        #expect(watchdog.log.records().isEmpty)

        // With the reporter unable to run, the main thread can still finish its answer.
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        watchdog.probeOutstanding.store(true, ordering: .releasing)
        watchdog.probeReportQueue.suspend()
        watchdog.noteProbeAnswered(sentAt: 1, delayNanos: 3_000_000_000, cpuNanos: 1_000_000, observedAt: observedAt) { [overloaded] in
            #expect(!Thread.isMainThread)
            return overloaded
        }
        #expect(watchdog.log.records().isEmpty)
        let outstandingWhilePaused = watchdog.probeOutstanding.load(ordering: .acquiring)
        #expect(outstandingWhilePaused)
        watchdog.lastHangUptime.store(10, ordering: .releasing)
        watchdog.probeReportQueue.resume()
        watchdog.probeReportQueue.sync {}

        let outstandingAfterReport = watchdog.probeOutstanding.load(ordering: .acquiring)
        #expect(!outstandingAfterReport)
        let record = try #require(watchdog.log.records().first)
        #expect(record.details["verdict"] == JSONValue.string("starved"))
        #expect(record.details["cause"] == nil)  // this process's CPU was not read: no cause claimed
        #expect(record.duration == .seconds(3))
        #expect(watchdog.log.records().count == 1)
        recorder.drain()
        let entry = try #require(recorder.entries.first)
        #expect(entry.started == observedAt.addingTimeInterval(-3))
        let text = try String(contentsOf: entry.url, encoding: .utf8)
        #expect(text.contains("verdict: starved"))
        #expect(text.contains("state: recovered"))

        // This process kept 6 of the 10 cores busy meanwhile: our own queues starved it.
        watchdog.noteProbeAnswered(sentAt: 20, delayNanos: 3_000_000_000, cpuNanos: 0, processCores: { 6 },
                                   host: { [overloaded] in overloaded })
        watchdog.probeReportQueue.sync {}
        let ours = try #require(watchdog.log.records().last)
        #expect(ours.details["cause"] == JSONValue.string("own-queues"))
        #expect(ours.details["process_cores"] == JSONValue.number(6))
        #expect(watchdog.log.records().count == 2)

        // A hang the watchdog already reported in that window keeps its own record.
        watchdog.lastHangUptime.store(30, ordering: .releasing)
        watchdog.noteProbeAnswered(sentAt: 25, delayNanos: 3_000_000_000, cpuNanos: 0, host: { [overloaded] in overloaded })
        watchdog.probeReportQueue.sync {}
        #expect(watchdog.log.records().count == 2)
    }
}
