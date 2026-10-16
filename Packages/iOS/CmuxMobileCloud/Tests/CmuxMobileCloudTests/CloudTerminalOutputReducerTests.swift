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

@Suite("Cloud terminal labels")
struct CloudTerminalLabelTests {
    @Test("Home directories read as ~, other paths stay as they are")
    func homeRelativePaths() {
        #expect(CloudTerminalSummary.homeRelativePath("/home/cmux") == "~")
        #expect(CloudTerminalSummary.homeRelativePath("/home/cmux/api") == "~/api")
        #expect(CloudTerminalSummary.homeRelativePath("/Users/aziz/Dev/cmux") == "~/Dev/cmux")
        #expect(CloudTerminalSummary.homeRelativePath("/root/app/") == "~/app")
        #expect(CloudTerminalSummary.homeRelativePath("/srv/app") == "/srv/app")
        #expect(CloudTerminalSummary.homeRelativePath("/home") == "/home")
        #expect(CloudTerminalSummary.homeRelativePath("  ") == nil)
    }

    @Test("Name, then title, then a directory that says something")
    func descriptiveName() {
        #expect(CloudTerminalSummary(id: "t", name: " server ", title: "vim").descriptiveName == "server")
        #expect(CloudTerminalSummary(id: "t", name: "", title: "vim").descriptiveName == "vim")
        #expect(CloudTerminalSummary(id: "t", currentDirectory: "/home/cmux/api").descriptiveName == "~/api")
        #expect(CloudTerminalSummary(id: "t", currentDirectory: "/home/cmux").descriptiveName == nil)
        #expect(CloudTerminalSummary(id: "t").descriptiveName == nil)
        #expect(CloudTerminalSummary(id: "t").displayName == "t")
    }
}
