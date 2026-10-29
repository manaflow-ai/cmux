import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

@MainActor
@Suite struct WorkspaceDeltaTests {
    nonisolated static let snapshot = #"{"ok":true,"data":{"workspace_revision":1,"workspaces":[{"id":1,"key":"one","name":"First","screens":[{"id":1,"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[{"surface":1,"kind":"pty","title":"Before"}]}]}]},{"id":2,"key":"two","name":"Second","screens":[]}]}}"#

    @Test func titleDeltaUpdatesOneRowWithoutFullFetch() async throws {
        let requests = CommandLog()
        let link = MockMacLink { _, data in
            data.split(separator: 0x0A).compactMap { line in
                guard let request = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let id = request["id"] as? String else { return nil }
                let command = request["cmd"] as? String ?? ""
                requests.append(command, nil)
                let body = command == "list-workspaces" ? Self.snapshot : #"{"ok":true,"data":{}}"#
                return Data(("{\"id\":\"\(id)\"," + body.dropFirst() + "\n").utf8)
            }
        }
        let sync = WorkspaceSync(deviceID: "test", deviceName: "iPhone")
        await sync.bind(try await link.openChannel(service: "daemon", args: [:]), macID: "mac")
        await sync.refresh()
        let before = try #require(sync.tree)
        let count = requests.count
        sync.handle(.titleChanged(surface: 1, title: "After"))
        for _ in 0..<5000 where sync.tree?.workspaces[0].tabs[0].title != "After" { await Task.yield() }
        let after = try #require(sync.tree)
        #expect(after.workspaces[0].tabs[0].title == "After")
        #expect(after.workspaces[1] == before.workspaces[1])
        #expect(requests.count == count)
        await sync.bind(nil, macID: "mac")
    }
}
