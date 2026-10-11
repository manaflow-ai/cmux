@testable import CmuxMobileSSH
import Foundation
import Testing

/// Hosts saved before Round 3 carry a per-host `persistence` mode. It is
/// ignored now (every host serves every kind) but must keep decoding.
struct SSHHostRecordLegacyDecodingTests {
    private static let hostJSON = #"""
    {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Box","endpoint":{"host":"10.0.0.2","port":22,"username":"me"},
     "keyID":"7F9619FF-8B86-D011-B42D-00C04FC964FF","persistence":"%@","idleClose":"sevenDays","createdAt":700000000}
    """#

    @Test(arguments: ["tmux", "cmuxTUI", "plain", "mosh", "somethingNewer"])
    func legacyPersistenceDecodes(mode: String) throws {
        let json = Self.hostJSON.replacingOccurrences(of: "%@", with: mode)
        let hosts = try JSONDecoder().decode([SSHHostRecord].self, from: Data("[\(json)]".utf8))
        let host = try #require(hosts.first)
        #expect(host.name == "Box")
        #expect(host.endpoint.host == "10.0.0.2")
        #expect(host.idleClose == .sevenDays)
        #expect(host.persistence?.rawValue == (mode == "somethingNewer" ? nil : mode))
    }

    @Test func hostWithoutPersistenceOrIdleCloseDecodes() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Box","endpoint":{"host":"h","port":2222,"username":"u"},"createdAt":1}]"#
        let host = try #require(try JSONDecoder().decode([SSHHostRecord].self, from: Data(json.utf8)).first)
        #expect(host.persistence == nil)
        #expect(host.idleClose == .oneDay)
        #expect(host.endpoint.port == 2222)
    }

    @Test func roundTripsThroughTheStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = Self.hostJSON.replacingOccurrences(of: "%@", with: "tmux")
        try Data("[\(json)]".utf8).write(to: dir.appendingPathComponent("ssh-hosts.json"))
        let store = SSHHostStore(directory: dir)
        #expect(await store.all().map(\.name) == ["Box"])
    }
}

struct CmuxTUISessionSocketParsingTests {
    @Test func firstDirectoryWinsAndInvalidNamesAreSkipped() {
        let output = """
        /run/user/501/cmux-tui-501/main.sock
        /var/folders/x/T/cmux-tui-501/work.sock
        /tmp/cmux-tui-501/main.sock
        /tmp/cmux-tui-501/.sock
        not-a-socket
        /tmp/cmux-tui-501/cmux-ios.sock
        """
        let sockets = CmuxTUIRemote.parseSessionSockets(output)
        #expect(sockets.map(\.name) == ["main", "work", "cmux-ios"])
        #expect(sockets.first?.path == "/run/user/501/cmux-tui-501/main.sock")
    }
}

struct CmuxTUITreeScreensTests {
    /// `list-workspaces` keeps screen and pane structure for the grouped
    /// tab switcher: screen names, active pane, and pane order.
    @Test func screensAndPanesDecodeInLayoutOrder() throws {
        let json = #"""
        {"workspace_revision":1,"workspaces":[{"id":4,"key":"k","name":"1","active":true,"screens":[
          {"id":3,"name":"dev","active":true,"active_pane":6,"panes":[
            {"id":2,"name":null,"active_tab":0,"tabs":[{"surface":1,"kind":"pty","title":"a","dead":false}]},
            {"id":6,"name":"logs","active_tab":1,"tabs":[{"surface":7,"kind":"pty","title":"b"},{"surface":8,"kind":"pty","title":"c"}]}]},
          {"id":9,"name":null,"panes":[{"id":10,"tabs":[{"surface":11,"kind":"pty","title":"d"}]}]}]}]}
        """#
        let workspace = try #require(try CmuxTUITreeWire(cmuxTUILine: Data(json.utf8)).model.first)
        #expect(workspace.screens.map(\.id) == [3, 9])
        #expect(workspace.screens.map(\.name) == ["dev", nil])
        #expect(workspace.screens.first?.activePane == 6)
        #expect(workspace.screens.first?.panes.map(\.id) == [2, 6])
        #expect(workspace.screens.first?.panes.last?.name == "logs")
        #expect(workspace.terminals.map(\.surface) == [1, 7, 8, 11])
        #expect(workspace.terminals.map(\.screen) == [3, 3, 3, 9])
    }
}
