import CmuxNextCloudUI
import Foundation
import Testing

/// Settings > Accounts > Cloud Environments: the list, Save, Build and Delete through the app's seams.
/// Build and Delete ask the person natively first; a no sends nothing and is not an error.
@MainActor @Suite(.serialized) struct CloudEnvironmentsSettingsTests {
    @MainActor final class Backend {
        var raw: [Data] = []
        /// The string-only saves; one with variables reads from ``raw``.
        var saved: [[String: String?]] { raw.compactMap { try? JSONDecoder().decode([String: String?].self, from: $0) } }
        var approved: [(op: String, id: String)] = []
        var lists = 0
        var confirms = 0
        var answerYes = true
        var available = true
        let listJSON = Data("""
        {"environments": [{"id": "env_00000000000000000001", "name": "web", "repo": "octo/paint", "setup_script": "bun install", "status": "failed",
          "env": [{"name": "NODE_ENV", "value": "development"}, {"name": "OPENAI_API_KEY", "secret": "openai"}],
          "last_build": {"state": "failed", "error": {"code": "cloud.environment.build_failed", "message": "setup exited 3"}, "log_tail": "lockfile mismatch"}}]}
        """.utf8)
    }

    private func model(_ b: Backend) -> CloudEnvironmentsSettings {
        CloudEnvironmentsSettings(
            available: { b.available },
            list: { b.lists += 1; return b.listJSON },
            save: { args in b.raw.append(args) },
            approvedCall: { op, id, confirm in
                guard await confirm() else { return false }
                b.approved.append((op, id))
                return true
            },
            confirm: { _, _, _ in b.confirms += 1; return b.answerYes })
    }

    @Test func refreshListsEnvironmentsWithTheirLastBuild() async throws {
        let b = Backend()
        let m = model(b)
        _ = await m.run(.init(action: .refresh))
        #expect(m.state.available)
        let row = try #require(m.state.environments.first)
        #expect(row.id == "env_00000000000000000001" && row.status == "failed")
        #expect(row.error == "setup exited 3")
        #expect(row.logTail == "lockfile mismatch")
        #expect(row.env == [.init(name: "NODE_ENV", value: "development"), .init(name: "OPENAI_API_KEY", secret: "openai")])
        // The page reads the row as the model encodes it.
        let page = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any]
        #expect(page?["log_tail"] as? String == "lockfile mismatch" && page?["setup_script"] as? String == "bun install")
    }

    @Test func saveSendsOnlyTheGivenFieldsAndAnEmptyRepoClearsIt() async throws {
        let b = Backend()
        let m = model(b)
        #expect(await m.run(.init(action: .save, name: "api", repo: "octo/api", setupScript: "make deps")).error == nil)
        #expect(await m.run(.init(action: .save, id: "env_00000000000000000001", repo: "")).error == nil)
        let created: [String: String?] = ["name": "api", "repo": "octo/api", "setup_script": "make deps"]
        let cleared: [String: String?] = ["environment": "env_00000000000000000001", "repo": String?.none]
        #expect(b.saved.first == created)
        #expect(b.saved.last == cleared)
        #expect(b.lists == 2, "each save reads the list again")
    }

    @Test func saveSendsTheVariablesAsCloudDOTakesThem() async throws {
        let b = Backend()
        let m = model(b)
        let env: [CloudEnvironmentVariable] = [.init(name: "NODE_ENV", value: "development"), .init(name: "OPENAI_API_KEY", secret: "openai")]
        #expect(await m.run(.init(action: .save, id: "env_00000000000000000001", env: env)).error == nil)
        let last = try #require(b.raw.last)
        let sent = try #require(try JSONSerialization.jsonObject(with: last) as? [String: Any])
        #expect(sent["environment"] as? String == "env_00000000000000000001")
        #expect(sent["name"] == nil && sent["repo"] == nil && sent["setup_script"] == nil, "only the edited field")
        let rows = try #require(sent["env"] as? [[String: String]])
        #expect(rows == [["name": "NODE_ENV", "value": "development"], ["name": "OPENAI_API_KEY", "secret": "openai"]])
    }

    @Test func buildAndDeleteAskTheNativeConfirmationFirst() async throws {
        let b = Backend()
        let m = model(b)
        _ = await m.run(.init(action: .refresh))
        #expect(await m.run(.init(action: .build, id: "env_00000000000000000001")).error == nil)
        b.answerYes = false
        #expect(await m.run(.init(action: .delete, id: "env_00000000000000000001")).error == nil, "a declined confirmation is not an error")
        #expect(b.confirms == 2)
        #expect(b.approved.map(\.op) == ["cloud.environment.build"])
    }

    @Test func theClassicCloudPathHasNoEnvironments() async throws {
        let b = Backend()
        b.available = false
        let m = model(b)
        _ = await m.run(.init(action: .refresh))
        #expect(!m.state.available)
        #expect(b.lists == 0, "nothing reaches the app server on the classic path")
        #expect(await m.run(.init(action: .save, name: "x")).error != nil)
    }
}
