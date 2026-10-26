import AppKit
import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import CmuxNextWakeups
import Testing

/// A chat open's marks in every build (p09-observability task 044): each is one `create.tab` instant of the chat
/// kind with its stage, every time it happens and with no `debug.chat_open_trace` armed, so a Release recording
/// shows the stages inside the open's `create.tab` pair.
@MainActor
struct ChatOpenTraceRingTests {
    /// The records a test runtime writes, in order.
    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        /// A runtime recording into this log, with only `categories` on.
        func runtime(_ categories: [SignpostCategory]) -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(categories.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) })
            return runtime
        }
    }

    private func trace(_ log: RecordLog, _ categories: [SignpostCategory] = [.create]) -> ChatOpenTrace {
        ChatOpenTrace(signposter: Signposter(category: .create, mirror: SignpostMetricKitMirror(), trace: log.runtime(categories)))
    }

    private static let chat = CreateTabInterval.Kind.chat.traceCode

    @Test("Each chat site's mark is a create.tab instant of the chat kind with its stage, armed or not, every time")
    func eachMarkIsAnInstant() throws {
        let log = RecordLog()
        let trace = trace(log)
        let pane = NSView()
        let page = NSObject()
        trace.mark(.panePainted, view: pane)
        trace.mark(.committed, page: page)
        trace.mark(.loadingLeft, view: NSView())
        trace.mark(.committed, page: page)  // a repeat of the stage: written too
        let records = log.records
        #expect(records.allSatisfy { $0.name == SignpostName.createTab.rawValue && $0.phase == .instant })
        #expect(records.allSatisfy { $0.categoryBit == SignpostCategory.create.traceBit })
        #expect(records.map(\.arg0) == [ChatOpenTrace.Mark.panePainted, .committed, .loadingLeft, .committed]
            .map { Self.chat | $0.traceCode << 8 })
        try #require(records.count == 4)
        #expect(records[0].arg1 == UInt64(UInt(bitPattern: ObjectIdentifier(pane))), "a view's mark carries its trace id")
        #expect(records[1].arg1 == UInt64(UInt(bitPattern: ObjectIdentifier(page))), "a page's mark carries its trace id")
        #expect(records[2].arg1 != records[0].arg1)
    }

    @Test("A shared site's mark (any pane's hold, any Chromium window) writes nothing unless a trace matched it")
    func sharedSitesNeedTheirChat() {
        let log = RecordLog()
        let trace = trace(log)
        trace.mark(.holdBegin, view: NSView())
        trace.mark(.holdEnd, view: NSView())
        #if DEBUG || CMUX_BENCH_HOOKS
        trace.mark(.cefWindowCreated, chromiumPane: "pane-1")
        trace.mark(.firstContentfulPaint, chromiumPane: "pane-1")
        #endif
        #expect(log.records.isEmpty)
        #expect(ChatOpenTrace.Mark.allCases.filter(\.isFromSharedSite)
            == [.holdBegin, .cefWindowCreate, .cefWindowCreated, .firstContentfulPaint, .holdEnd])
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    @Test("An armed trace's own Chromium pane and hold write their instants, once per stage")
    func armedSharedSitesWriteTheirChatsStages() {
        let log = RecordLog()
        let trace = trace(log)
        #expect(trace.begin())
        trace.chromiumPane = "pane-1"
        trace.mark(.cefWindowCreated, chromiumPane: "pane-2")  // another window
        trace.mark(.cefWindowCreated, chromiumPane: "pane-1")
        trace.mark(.cefWindowCreated, chromiumPane: "pane-1")
        let pane = NSView()
        trace.mark(.holdBegin, view: pane)
        _ = trace.finish(timedOut: false)
        let expected = [ChatOpenTrace.Mark.cefWindowCreated, .holdBegin].map { Self.chat | $0.traceCode << 8 }
        #expect(log.records.map(\.arg0) == expected)
    }
    #endif

    @Test("A stage instant never reads as the stand-in commit's: its stage bits are never 0")
    func stagesAreNotTheStandIn() {
        let codes = ChatOpenTrace.Mark.allCases.map(\.traceCode)
        #expect(codes == Array(1...UInt64(codes.count)))
        #expect(codes.allSatisfy { $0 <= 0xFF })
    }

    @Test("With the create category off, a mark writes nothing")
    func offWritesNothing() {
        let log = RecordLog()
        trace(log, [.burst]).mark(.loadingLeft, view: NSView())
        #expect(log.records.isEmpty)
    }
}
