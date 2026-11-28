import Foundation
import Testing
@testable import CmuxNextDaemon

/// The exact request lines of the terminal-spawning layout requests (`split`, `new-pane`,
/// `new-pane-right`, `new-tab`): their own fields plus `SpawnOptions` encoded flat. These bytes
/// are the contract the generated types (swift_app `spread` and `constant`) keep with the
/// hand-written ones they replaced.
struct SpawnRequestWireTests {
    private func line(_ request: some DaemonRequest) throws -> String {
        String(decoding: try WireCoding.encodeRequest(request, id: 7), as: UTF8.self)
    }

    /// Every field `SpawnOptions` carries, set.
    private static var everyOption: SpawnOptions {
        var options = SpawnOptions(cwd: "/tmp", size: CellSize(cols: 80, rows: 24), argv: ["zsh"], command: "ls",
                                   name: "n", env: ["lang": "c"], keep: true)
        options.terminalID = "t1"
        options.shellArgs = ["-l"]
        options.paneID = "p1"
        options.tabID = "b1"
        options.splitID = "s1"
        options.around = 9
        return options
    }

    @Test func aSplitSendsItsFieldsAndEveryOptionFlat() throws {
        #expect(try line(SplitRequest(pane: 3, direction: .right, options: Self.everyOption, before: true))
            == #"{"argv":["zsh"],"around":9,"before":true,"cmd":"split","cols":80,"command":"ls","cwd":"/tmp","dir":"right","env":{"lang":"c"},"id":7,"keep":true,"name":"n","pane":3,"pane_id":"p1","rows":24,"shell_args":["-l"],"split_id":"s1","tab_id":"b1","terminal_id":"t1"}"#)
    }

    @Test func aPlainSplitSendsItsPaneAndDirection() throws {
        #expect(try line(SplitRequest(pane: 3, direction: .down))
            == #"{"cmd":"split","dir":"down","id":7,"pane":3}"#)
    }

    @Test func aNewPaneSendsItsOptions() throws {
        var options = SpawnOptions(cwd: "/tmp")
        options.paneID = "p1"
        options.tabID = "b1"
        #expect(try line(NewPaneRequest(pane: 3, options: options))
            == #"{"cmd":"new-pane","cwd":"/tmp","id":7,"pane":3,"pane_id":"p1","tab_id":"b1"}"#)
    }

    @Test func aLeftColumnSendsItsSide() throws {
        var options = SpawnOptions()
        options.terminalID = "t1"
        #expect(try line(NewColumnRequest(pane: 3, width: 0.5, left: true, options: options))
            == #"{"cmd":"new-pane-right","id":7,"pane":3,"side":"left","terminal_id":"t1","width":0.5}"#)
        #expect(try line(NewColumnRequest(pane: 3)) == #"{"cmd":"new-pane-right","id":7,"pane":3}"#)
    }

    @Test func aNewTabSendsItsPaneOnlyWhenSet() throws {
        #expect(try line(NewTabRequest(pane: nil, options: SpawnOptions(keep: true)))
            == #"{"cmd":"new-tab","id":7,"keep":true}"#)
        #expect(try line(NewTabRequest(pane: 3, options: SpawnOptions(size: CellSize(cols: 80, rows: 24))))
            == #"{"cmd":"new-tab","cols":80,"id":7,"pane":3,"rows":24}"#)
    }
}
