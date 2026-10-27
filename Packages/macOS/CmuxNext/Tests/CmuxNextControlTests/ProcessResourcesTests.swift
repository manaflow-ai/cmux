import CmuxNextCompat
import CmuxNextControl
import CmuxNextMetrics
import CmuxNextWakeups
import Testing

/// Task 121: the pids of a resource sample come from known sources only (what the main thread knows, the answers of
/// the daemon and acpmux, and what those processes started), every sample is taken in post order (a report never
/// overtakes a queued become-active, even behind the startup fence), a resign asks for the daemon's hosts and acpmux
/// without any report before it, and a become-active reuses the last answers. Over fake sources and a fake counter
/// provider.
@MainActor @Suite("Process resources sampling")
struct ProcessResourcesTests {
    private typealias Known = ProcessResources.KnownProcess

    /// The pids each sample read, in order. A sample reads the clock once, after its processes: that read closes its
    /// entry of ``samples``.
    final class Reads: Sendable {
        private struct State {
            var pids: [[Int32]] = []
            var current: [Int32] = []
            var uptimeNanos: UInt64 = 1_000_000_000_000
        }

        private let state = Mutex(State())

        var sources: ProcessResourceSampler.Sources {
            ProcessResourceSampler.Sources(uptimeNanos: {
                self.state.withLock { state in
                    state.pids.append(state.current)
                    state.current = []
                    return state.uptimeNanos
                }
            }, usage: { pid in
                self.state.withLock { $0.current.append(pid) }
                return ProcessResourceSampler.Usage(footprintBytes: 1_024 * 1_024, cpuNanos: 0, diskWriteBytes: 0, startTime: 1)
            })
        }

        var samples: [[Int32]] { state.withLock { $0.pids } }
    }

    /// One asked source: its answers in order (the last one repeats; a nil entry is no answer), and how often it was
    /// asked.
    final class Asked: Sendable {
        private struct State {
            var answers: [[Known]?]
            var calls = 0
        }

        private let state: Mutex<State>

        init(_ answers: [[Known]?]) {
            state = Mutex(State(answers: answers))
        }

        var calls: Int { state.withLock { $0.calls } }

        var ask: @Sendable () async -> [Known]? {
            {
                self.state.withLock { state in
                    state.calls += 1
                    return state.answers.count > 1 ? state.answers.removeFirst() : state.answers.first ?? nil
                }
            }
        }
    }

    private static func resources(_ reads: Reads, work: BackgroundWork = BackgroundWork(label: "test.process-resources"),
                                  current: [Known] = [Known(kind: .daemon, pid: 20)], asked: [Asked],
                                  listed: @escaping @Sendable ([Known]) -> [Known] = { _ in [Known(kind: .app, pid: 10)] })
        -> ProcessResources {
        ProcessResources(sampler: ProcessResourceSampler(sources: reads.sources), work: work,
                         sources: ProcessResources.Sources(current: { current }, asked: asked.map(\.ask), listed: listed))
    }

    @Test("A report never overtakes a queued become-active, even while the startup fence holds posted work")
    func reportKeepsTheOrderBehindTheFence() async {
        let reads = Reads()
        let work = BackgroundWork(label: "test.process-resources.order")
        let resources = Self.resources(reads, work: work, asked: [])
        resources.appDidResignActive()
        await resources.sampleNow()
        #expect(resources.sampler.isMeasuringIdle)

        work.beginBestEffortFence()
        resources.appDidBecomeActive()
        await resources.sampleNow()
        work.endBestEffortFence()

        #expect(!resources.sampler.isMeasuringIdle, "the become-active closed the idle period before the report ran")
        #expect(resources.sampler.tally() == ProcessResourceSampler.Tally(recorded: [.resignActive: 1, .becomeActive: 1, .report: 2]))
    }

    @Test("A resign with no report before it reads the daemon's hosts and acpmux; a become-active reuses them")
    func resignAsksBecomeActiveReuses() async {
        let reads = Reads()
        let hosts = Asked([[Known(kind: .host, pid: 30)]])
        let acpmux = Asked([[Known(kind: .acpmux, pid: 40), Known(kind: .agentHost, pid: 41)]])
        let resources = Self.resources(reads, asked: [hosts, acpmux])

        resources.appDidResignActive()
        resources.appDidBecomeActive()
        await resources.sampleNow()

        #expect(reads.samples.count == 3)
        #expect(reads.samples.first == [10, 20, 30, 40, 41], "the first transition reads the hosts and acpmux")
        #expect(reads.samples.dropFirst().first == reads.samples.first, "the become-active reuses the resign's answers")
        #expect(hosts.calls == 2 && acpmux.calls == 2, "the resign and the report ask, the become-active does not")
    }

    @Test("A source that does not answer keeps its last answer")
    func unansweredSourceKeepsItsLastAnswer() async {
        let reads = Reads()
        let hosts = Asked([[Known(kind: .host, pid: 30)], nil])
        let resources = Self.resources(reads, current: [], asked: [hosts], listed: { _ in [] })
        await resources.sampleNow()
        await resources.sampleNow()
        #expect(reads.samples == [[30], [30]])
    }

    @Test("One sample records every kind the app's sources name: 8 or more")
    func oneSampleRecordsEveryKind() async throws {
        let reads = Reads()
        let current = [Known(kind: .daemon, pid: 20), Known(kind: .browserHost, pid: 22), Known(kind: .chromiumHost, pid: 50)]
        let hosts = Asked([[Known(kind: .host, pid: 30), Known(kind: .host, pid: 31)]])
        let acpmux = Asked([[Known(kind: .acpmux, pid: 40), Known(kind: .agentHost, pid: 41)]])
        let resources = Self.resources(reads, current: current, asked: [hosts, acpmux], listed: { known in
            // As the app's listing: this process, its helpers by type, and the Chromium host's helpers.
            [Known(kind: .app, pid: 10), Known(kind: .renderer, pid: 11), Known(kind: .gpu, pid: 12), Known(kind: .utility, pid: 13)]
                + (known.contains { $0.kind == .chromiumHost } ? [Known(kind: .renderer, pid: 51)] : [])
        })

        let sample = try #require(await resources.sampleNow())
        #expect(sample.kinds == [.app, .daemon, .host, .acpmux, .agentHost, .browserHost, .chromiumHost, .renderer, .gpu, .utility])
        #expect(sample.kinds.count >= 8)
        #expect(sample.memoryKiB[.host] == 2 * 1_024, "both hosts, under one kind")
    }

    @Test("A report when the queue's task cannot run (quit refused it) returns nil instead of waiting",
          .timeLimit(.minutes(1)))
    func reportWithoutTheQueueReturns() async {
        let reads = Reads()
        let work = BackgroundWork(label: "test.process-resources.shutdown")
        await work.shutdown()
        let resources = Self.resources(reads, work: work, asked: [])
        resources.appDidResignActive()
        #expect(await resources.sampleNow() == nil)
    }
}
