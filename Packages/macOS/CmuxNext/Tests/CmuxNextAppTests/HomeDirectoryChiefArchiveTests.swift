@testable import CmuxNextApp
import Foundation
import Testing

/// Red proof on the base: Archive Chief on the default (Hosted) Cloud Chief, and on any Chief while
/// the Cloud is unreachable, leaves the row in the list.
@MainActor @Suite(.serialized) struct HomeDirectoryChiefArchiveTests {
    @MainActor final class FakeAccount {
        var chiefs: [String: Bool] = [:]
        var offline = false
        func call(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            if offline { throw URLError(.notConnectedToInternet) }
            switch body["op"] as? String {
            case "chief.list":
                let list: [[String: Any]] = chiefs.sorted { $0.key < $1.key }.map { id, isDefault in
                    ["id": id, "display_name": "Chief", "is_default": isDefault, "rev": 1,
                     "main_conversation": "conv_\(id)", "archived_at": NSNull()]
                }
                return ["ok": true, "value": ["chiefs": list, "tombstones": [Any]()]]
            case "chief.archive":
                return ["_tag": "error", "code": "chief_is_default", "message": "make another chief the default first"]
            default:
                return ["ok": true]
            }
        }
    }

    @Test func theDefaultCloudChiefIsHiddenAndStaysHidden() async {
        let account = FakeAccount()
        account.chiefs = ["agent_cloud": true]
        let directory = HomeDirectory(call: { try await account.call($0, $1) }, me: { nil })
        await directory.refreshChiefs()
        _ = try? await directory.archiveChief("agent_cloud")
        #expect(directory.archivedChiefs.contains("agent_cloud"))
    }

    @Test func anOfflineArchiveHidesNowAndSyncsWhenReachable() async {
        let account = FakeAccount()
        account.chiefs = ["agent_main": true, "agent_side": false]
        let directory = HomeDirectory(call: { try await account.call($0, $1) }, me: { nil })
        await directory.refreshChiefs()
        account.offline = true
        _ = try? await directory.archiveChief("agent_side")
        #expect(directory.archivedChiefs.contains("agent_side"))
    }
}
