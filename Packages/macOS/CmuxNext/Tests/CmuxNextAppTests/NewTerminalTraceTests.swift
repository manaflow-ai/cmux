#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextWakeups
import Foundation
import Testing

struct NewTerminalTraceTests {
    private final class Identity {}

    private func started() -> NewTerminalTrace {
        let trace = NewTerminalTrace()
        #expect(trace.begin())
        trace.markAction()
        trace.bind(terminal: "terminal-1")
        trace.tabAdded(terminal: "terminal-1", surface: 1 << 62, terminalResourceID: "term_1")
        return trace
    }

    @Test func resolvedSurfaceIsUsedForCleanup() {
        let trace = started()
        trace.tabAdded(terminal: "terminal-1", surface: 42, terminalResourceID: "term_1")
        trace.mark(.attachStart, surface: 42, terminalResourceID: "term_1")
        trace.mark(.attachReplied, surface: 0, terminalResourceID: "term_1")
        trace.mark(.attachEnd, surface: 42, terminalResourceID: "term_1")

        let record = trace.finish(timedOut: false)
        #expect(record?.surface == 42)
        #expect(record?.milliseconds(.attachStart) != nil)
        #expect(record?.milliseconds(.attachReplied) != nil)
        #expect(record?.milliseconds(.attachEnd) != nil)
    }

    @Test func unrelatedAttachmentsCannotCompleteTrace() {
        let trace = started()
        trace.tabAdded(terminal: "terminal-2", surface: 99, terminalResourceID: "term_2")
        trace.mark(.attachStart, surface: 99, terminalResourceID: "term_2")
        trace.mark(.attachReplied, surface: 0, terminalResourceID: "term_2")
        trace.mark(.attachEnd, surface: 0)

        let record = trace.finish(timedOut: true)
        #expect(record?.surface == 1 << 62)
        #expect(record?.milliseconds(.attachStart) == nil)
        #expect(record?.milliseconds(.attachReplied) == nil)
        #expect(record?.milliseconds(.attachEnd) == nil)
    }

    @Test(arguments: [true, false]) func replacementViewReportsOutputAndRejectsOldView(oldOnly: Bool) {
        let trace = started()
        let oldIO = Identity(), oldSession = Identity(), oldLane = Identity(), oldLayer = Identity()
        let newIO = Identity(), newSession = Identity(), newLane = Identity(), newLayer = Identity()
        trace.watch(io: ObjectIdentifier(oldIO), surface: 1 << 62)
        #expect(trace.sessionCreated(io: ObjectIdentifier(oldIO), session: ObjectIdentifier(oldSession),
                                     lane: ObjectIdentifier(oldLane), layer: ObjectIdentifier(oldLayer)))
        trace.tabAdded(terminal: "terminal-1", surface: 42, terminalResourceID: "term_1")
        trace.watch(io: ObjectIdentifier(newIO), surface: 42)
        #expect(trace.sessionCreated(io: ObjectIdentifier(newIO), session: ObjectIdentifier(newSession),
                                     lane: ObjectIdentifier(newLane), layer: ObjectIdentifier(newLayer)))
        #expect(!trace.sessionCreated(io: ObjectIdentifier(oldIO), session: ObjectIdentifier(oldSession),
                                      lane: ObjectIdentifier(oldLane), layer: ObjectIdentifier(oldLayer)))
        let prompt = Data([0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x41])
        trace.contentOnMain(session: ObjectIdentifier(oldSession))
        trace.parsed(lane: ObjectIdentifier(oldLane), prompt)
        trace.contents(layer: ObjectIdentifier(oldLayer))
        if !oldOnly {
            trace.contentOnMain(session: ObjectIdentifier(newSession))
            trace.parsed(lane: ObjectIdentifier(newLane), prompt)
            trace.contents(layer: ObjectIdentifier(newLayer))
        }
        let record = trace.finish(timedOut: false)
        #expect(record?.surface == 42)
        for mark in [NewTerminalTrace.Mark.firstOutputMain, .firstParsed, .firstContents, .promptParsed, .promptContents] {
            #expect((record?.milliseconds(mark) != nil) == !oldOnly)
        }
    }

    @Test func unrelatedViewCannotReportOutput() {
        let trace = started()
        let io = Identity(), session = Identity(), lane = Identity(), layer = Identity()
        trace.watch(io: ObjectIdentifier(io), surface: 99)
        #expect(!trace.sessionCreated(io: ObjectIdentifier(io), session: ObjectIdentifier(session),
                                      lane: ObjectIdentifier(lane), layer: ObjectIdentifier(layer)))
        trace.contentOnMain(session: ObjectIdentifier(session))
        trace.parsed(lane: ObjectIdentifier(lane), Data([0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x41]))
        trace.contents(layer: ObjectIdentifier(layer))
        let record = trace.finish(timedOut: true)
        for mark in [NewTerminalTrace.Mark.firstOutputMain, .firstParsed, .firstContents, .promptParsed, .promptContents] {
            #expect(record?.milliseconds(mark) == nil)
        }
    }
}
#endif
