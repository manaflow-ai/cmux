import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextMetrics
import CmuxNextWakeups
import Foundation
import Testing

/// Task 121: the pids of a resource sample come from known sources only (this process and its helpers, the daemon's
/// `identify` pid and the daemon's `trace-status` children), the daemon's list is asked for at a report and reused by
/// the transitions after it, and a report's sample is recorded before ``ProcessResources/sampleNow()`` returns. Over a
/// fake process list, daemon status and counter provider.
@MainActor @Suite("Process resources sampling")
struct ProcessResourcesTests {
    private typealias Known = ProcessResources.KnownProcess

    /// The pids each sample read, in order, and the daemon status calls. A sample reads the clock once, after its
    /// processes: that read closes its entry of ``samples`` and is announced on ``sampled``.
    final class Reads: Sendable {
        private struct State {
            var pids: [[Int32]] = []
            var current: [Int32] = []
            var statusCalls = 0
        }

        private let state = Mutex(State())
        let sampled: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            sampled = stream
            self.continuation = continuation
        }

        var sources: ProcessResourceSampler.Sources {
            ProcessResourceSampler.Sources(uptimeNanos: {
                self.state.withLock { state in
                    state.pids.append(state.current)
                    state.current = []
                }
                self.continuation.yield()
                return 1
            }, usage: { pid in
                self.state.withLock { $0.current.append(pid) }
                return ProcessResourceSampler.Usage(footprintBytes: 1_024 * 1_024, cpuNanos: 0, diskWriteBytes: 0, startTime: 1)
            })
        }

        var samples: [[Int32]] { state.withLock { $0.pids } }
        func countStatusCall() { state.withLock { $0.statusCalls += 1 } }
        var statusCalls: Int { state.withLock { $0.statusCalls } }
    }

    /// The daemon's answers in order, then none.
    final class Answers: Sendable {
        private let left: Mutex<[TraceStatusRequest.Response]>

        init(_ answers: [TraceStatusRequest.Response]) {
            left = Mutex(answers)
        }

        func next() -> TraceStatusRequest.Response? {
            left.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }
    }

    @Test("trace-status's hosts and acpmux become known processes; the daemon's own entry and pid-less ones do not")
    func childrenOfAStatus() throws {
        let json = Data("""
        {"processes":[{"role":"daemon","pid":20,"state":"idle"},{"role":"holder","state":"traced","reason":"holder_traced"},
        {"role":"terminal-host","pid":30,"state":"idle"},{"role":"terminal-host","pid":31,"state":"untraced"},
        {"role":"acpmux","pid":40,"state":"idle"}],"op":"status","recording":false}
        """.utf8)
        let status = try JSONDecoder().decode(TraceStatusRequest.Response.self, from: json)
        #expect(ProcessResources.children(of: status) == [Known(kind: .host, pid: 30), Known(kind: .host, pid: 31),
                                                         Known(kind: .acpmux, pid: 40)])
    }

    @Test("A report asks the daemon for its children; the transitions after it reuse them")
    func reportRefreshesTransitionsReuse() async {
        let reads = Reads()
        var sampled = reads.sampled.makeAsyncIterator()
        let resources = ProcessResources(
            sampler: ProcessResourceSampler(sources: reads.sources), work: BackgroundWork(label: "test.process-resources"),
            localProcesses: { [Known(kind: .app, pid: 10), Known(kind: .renderer, pid: 11)] },
            daemonPID: { 20 },
            daemonStatus: {
                reads.countStatusCall()
                return TraceStatusRequest.Response(processes: [.init(role: "terminal-host", pid: 30), .init(role: "acpmux", pid: 40)])
            })

        resources.appDidResignActive()
        _ = await sampled.next()
        #expect(reads.samples == [[10, 11, 20]], "before any report the daemon's children are not known")
        #expect(reads.statusCalls == 0, "a transition never asks the daemon")

        await resources.sampleNow()
        #expect(reads.samples.last == [10, 11, 20, 30, 40], "a report's sample is read before sampleNow returns")
        #expect(resources.sampler.tally().recorded[.report] == 1)
        _ = await sampled.next()

        resources.appDidBecomeActive()
        _ = await sampled.next()
        #expect(reads.samples.last == [10, 11, 20, 30, 40])
        #expect(reads.statusCalls == 1)
    }

    @Test("A daemon that does not answer keeps the children of its last answer")
    func unansweredStatusKeepsTheLastList() async {
        let reads = Reads()
        let answers = Answers([TraceStatusRequest.Response(processes: [.init(role: "terminal-host", pid: 30)])])
        let resources = ProcessResources(
            sampler: ProcessResourceSampler(sources: reads.sources), work: BackgroundWork(label: "test.process-resources.unanswered"),
            localProcesses: { [] }, daemonPID: { nil },
            daemonStatus: { answers.next() })
        await resources.sampleNow()
        await resources.sampleNow()
        #expect(reads.samples == [[30], [30]])
    }
}
