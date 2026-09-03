import Foundation
import Testing
@testable import CmuxMobileCloud

@Suite struct CloudTerminalOutputReducerTests {
    @Test func firstSnapshotAppliesGridThenWritesReplayWithoutReset() {
        var reducer = CloudTerminalOutputReducer()
        let replay = Data("$ ".utf8)
        #expect(reducer.reduce(.snapshot(replay: replay, cols: 80, rows: 24)) == [
            .applyGrid(cols: 80, rows: 24),
            .write(replay),
        ])
    }

    @Test func laterSnapshotIsPrefixedWithFullReset() {
        var reducer = CloudTerminalOutputReducer()
        _ = reducer.reduce(.snapshot(replay: Data("a".utf8), cols: 80, rows: 24))
        let actions = reducer.reduce(.snapshot(replay: Data("b".utf8), cols: 100, rows: 30))
        var expected = CloudTerminalOutputReducer.resetSequence
        expected.append(Data("b".utf8))
        #expect(actions == [.applyGrid(cols: 100, rows: 30), .write(expected)])
    }

    @Test func outputResizeAndExitMapDirectly() {
        var reducer = CloudTerminalOutputReducer()
        #expect(reducer.reduce(.output(Data("x".utf8))) == [.write(Data("x".utf8))])
        #expect(reducer.reduce(.output(Data())) == [])
        #expect(reducer.reduce(.resized(cols: 10, rows: 5)) == [.applyGrid(cols: 10, rows: 5)])
        #expect(reducer.reduce(.resized(cols: 0, rows: 5)) == [])
        #expect(reducer.reduce(.exited) == [.exited])
    }
}
