import CmuxMobileHost
import CmuxNextDaemon
@testable import CmuxNextMobileLink
import CmuxTerminalStream
import Foundation
import Testing

@Suite("terminal event mapper")
struct TerminalEventMapperTests {
    static func ready(generation: UInt64, offset: UInt64, cols: Int? = 80, rows: Int? = 24) -> TerminalChannelEvent {
        .snapshot(TerminalSnapshotFrame(phase: .ready, generation: generation, offset: offset, version: 1, cols: cols,
                                        rows: rows, data: Data("READY".utf8)))
    }

    @Test func aReadyKeepsItsCutAndLiveOutputCarriesTheRunningOffset() {
        var mapper = TerminalEventMapper()
        #expect(mapper.map(Self.ready(generation: 3, offset: 500)) == [
            .size(generation: 3, cols: 80, rows: 24),
            .frame(TerminalFrame(kind: .snapshotReady, generation: 3, offset: 500, snapshotVersion: 1, payload: Data("READY".utf8))),
        ])
        #expect(mapper.snapshotVersion == 1)
        #expect(mapper.map(.output(Data("ab".utf8), colors: nil)) == [
            .frame(TerminalFrame(kind: .bytes, generation: 3, offset: 502, payload: Data("ab".utf8))),
        ])
        #expect(mapper.map(.output(Data("c".utf8), colors: nil)) == [
            .frame(TerminalFrame(kind: .bytes, generation: 3, offset: 503, payload: Data("c".utf8))),
        ])
        let history = TerminalChannelEvent.snapshot(TerminalSnapshotFrame(phase: .history, generation: 3, offset: 500,
                                                                          version: 1, data: Data("H".utf8)))
        #expect(mapper.map(history) == [
            .frame(TerminalFrame(kind: .snapshotHistory, generation: 3, offset: 500, snapshotVersion: 1, payload: Data("H".utf8))),
        ])
    }

    @Test func aGridChangeIsASizeThenItsReadyAndAnUnchangedReadyIsJustTheFrame() {
        var mapper = TerminalEventMapper()
        _ = mapper.map(Self.ready(generation: 3, offset: 500))
        let resync = mapper.map(Self.ready(generation: 3, offset: 900))
        #expect(resync.count == 1)
        let grown = mapper.map(Self.ready(generation: 4, offset: 950, cols: 120, rows: 40))
        #expect(grown.first == .size(generation: 4, cols: 120, rows: 40))
        #expect(mapper.map(.closed(.surfaceGone)) == [.closed])
        #expect(mapper.map(.scrollChanged(offset: 1, atBottom: true)).isEmpty)
    }

    @Test func anOlderHostsByteReplayFeedsBytesAndAResizeResetsTheMirror() {
        var mapper = TerminalEventMapper()
        let first = mapper.map(.replay(TerminalReplay(cols: 80, rows: 24, data: Data("abc".utf8))))
        #expect(first == [.size(generation: 0, cols: 80, rows: 24),
                          .frame(TerminalFrame(kind: .bytes, generation: 0, offset: 3, payload: Data("abc".utf8)))])
        #expect(mapper.snapshotVersion == nil)
        let resized = mapper.map(.resized(TerminalReplay(cols: 40, rows: 20, data: Data("x".utf8))))
        #expect(resized.last == .frame(TerminalFrame(kind: .bytes, generation: 1, offset: 6, payload: Data("\u{1b}cx".utf8))))
    }
}
