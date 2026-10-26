@testable import CmuxNextApp
import Foundation
import Testing

/// Archive Chief on the "Chief · Cloud" row did nothing: the Hosted Chief is the account's
/// default, the cloud refuses `chief.archive` for it (`chief_is_default`), an unreachable Cloud
/// fails the call, and the row menu's run dropped either failure. Archive now hides the Chief on
/// this Mac at once and keeps it hidden, and the cloud archive follows when it can run.
@MainActor @Suite(.serialized) struct HomeDirectoryChiefArchiveTests {
    /// The account's API (UserDO's `chief.list` and `chief.archive`, refusing as the Worker does).
    @MainActor final class FakeAccount {
        var chiefs: [String: (isDefault: Bool, rev: Int, archived: Bool)] = [:]
        var offline = false
        var refuseArchive: String?
        var archives: [String] = []

        func call(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            if offline { throw URLError(.notConnectedToInternet) }
            let params = body["params"] as? [String: Any] ?? [:]
            switch body["op"] as? String {
            case "chief.list":
                let list: [[String: Any]] = chiefs.sorted { $0.key < $1.key }.map { id, chief in
                    return ["id": id, "display_name": "Chief", "is_default": chief.isDefault, "rev": chief.rev,
                            "main_conversation": "conv_\(id)", "archived_at": chief.archived ? "2026-10-26T00:00:00Z" : NSNull()]
                }
                return ["ok": true, "value": ["chiefs": list, "tombstones": [Any]()]]
            case "chief.archive":
                let id = params["chief"] as? String ?? ""
                archives.append(id)
                if let code = refuseArchive { return ["_tag": "error", "code": code, "message": "refused: \(code)"] }
                guard let chief = chiefs[id] else { return ["_tag": "error", "code": "selector.not_found", "message": "chief not found"] }
                if chief.isDefault { return ["_tag": "error", "code": "chief_is_default", "message": "make another chief the default first"] }
                chiefs[id] = (chief.isDefault, chief.rev + 1, true)
                return ["ok": true, "value": ["id": id]]
            default:
                return ["ok": true]
            }
        }
    }

    let defaults: UserDefaults

    init() {
        let suite = "HomeDirectoryChiefArchiveTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
    }

    func directory(_ account: FakeAccount) -> HomeDirectory {
        HomeDirectory(call: { try await account.call($0, $1) }, me: { nil }, archiveStore: HomeChiefArchiveStore(defaults: defaults))
    }

    /// The Hosted Chief (the default one) leaves the list and stays gone, also after a relaunch and a
    /// fresh `chief.list`; the cloud is not asked for an archive it always refuses.
    @Test func theDefaultCloudChiefIsHiddenAndStaysHidden() async {
        let account = FakeAccount()
        account.chiefs = ["agent_cloud": (true, 2, false)]
        let directory = directory(account)
        await directory.refreshChiefs()

        #expect(await directory.archiveChief("agent_cloud") == .hiddenHere)
        #expect(directory.archivedChiefs.contains("agent_cloud"))
        #expect(account.archives.isEmpty)

        let relaunched = self.directory(account)
        #expect(relaunched.archivedChiefs.contains("agent_cloud"))
        await relaunched.refreshChiefs()
        #expect(relaunched.archivedChiefs.contains("agent_cloud"))
    }

    /// Offline: the row goes at once; the cloud archive runs at the next list read that answers.
    @Test func anOfflineArchiveHidesNowAndSyncsWhenReachable() async {
        let account = FakeAccount()
        account.chiefs = ["agent_main": (true, 1, false), "agent_side": (false, 4, false)]
        let directory = directory(account)
        await directory.refreshChiefs()
        account.offline = true

        #expect(await directory.archiveChief("agent_side") == .hiddenHere)
        #expect(directory.archivedChiefs.contains("agent_side"))
        #expect(account.archives.isEmpty)

        account.offline = false
        await directory.refreshChiefs()
        #expect(account.archives == ["agent_side"])
        #expect(account.chiefs["agent_side"]?.archived == true)
        #expect(directory.archivedChiefs.contains("agent_side"))
        #expect(directory.archivedHere.isEmpty)
    }

    /// A reachable archive lands in the cloud and needs nothing kept on this Mac.
    @Test func aReachableArchiveLandsInTheCloud() async {
        let account = FakeAccount()
        account.chiefs = ["agent_main": (true, 1, false), "agent_side": (false, 4, false)]
        let directory = directory(account)
        await directory.refreshChiefs()

        #expect(await directory.archiveChief("agent_side") == .archived)
        #expect(account.chiefs["agent_side"]?.archived == true)
        #expect(directory.archivedChiefs.contains("agent_side"))
        #expect(directory.archivedHere.isEmpty)
    }

    /// Any other refusal brings the row back and says why, instead of nothing happening.
    @Test func aRefusalShowsTheRowAgainAndSaysWhy() async {
        let account = FakeAccount()
        account.chiefs = ["agent_main": (true, 1, false), "agent_side": (false, 4, false)]
        account.refuseArchive = "policy.denied"
        let directory = directory(account)
        await directory.refreshChiefs()

        #expect(await directory.archiveChief("agent_side") == .refused("refused: policy.denied"))
        #expect(!directory.archivedChiefs.contains("agent_side"))
    }
}
