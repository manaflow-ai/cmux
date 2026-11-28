@testable import CmuxNextAgentIntegrations
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

@MainActor struct SettingsDeveloperTokensTests {
    nonisolated static let cliURL = URL(fileURLWithPath: "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux")

    private func repositoryArguments(_ filters: [String: JSONValue]) throws -> [String] {
        var params: [String: JSONValue] = ["repository": "owner/repo", "scopes": ["machines"]]
        params.merge(filters) { _, value in value }
        return try SettingsDeveloperTokens.arguments(action: "allowRepository", params: .object(params),
                                                     list: ["canManageTeamTokens": true], rules: .null)
    }

    @Test func invalidRepositoryFiltersCannotBecomeUnrestricted() {
        let invalid: [JSONValue] = [.string("release\nproduction"), .string(String(repeating: "x", count: 256)), .bool(true)]
        for key in ["ref", "environment"] {
            for value in invalid {
                #expect(throws: PageError.self) { _ = try repositoryArguments([key: value]) }
            }
        }
    }

    @Test func validRepositoryFiltersArePreserved() throws {
        let words = try repositoryArguments(["ref": " refs/heads/release/* ", "environment": " production "])
        #expect(words == ["github", "allow", "--repository=owner/repo", "--ref=refs/heads/release/*",
                          "--environment=production", "--scope=machines"])
        for key in ["ref", "environment"] {
            let boundary = String(repeating: "x", count: 255)
            #expect(try repositoryArguments([key: .string(boundary)]).contains("--\(key)=\(boundary)"))
        }
    }

    @Test func absentOrEmptyRepositoryFiltersRemainUnrestricted() throws {
        let unrestricted = ["github", "allow", "--repository=owner/repo", "--scope=machines"]
        #expect(try repositoryArguments([:]) == unrestricted)
        let empty: [JSONValue] = [.null, .string(""), .string(" \t ")]
        for value in empty {
            #expect(try repositoryArguments(["ref": value, "environment": value]) == unrestricted)
        }
    }

    /// The first lookup can be held until a later refresh has completed.
    nonisolated final class Recorder: @unchecked Sendable {
        var cliCalls = 0
        var runCalls = 0
        var releaseFirstCLI: CheckedContinuation<URL?, Never>?
        var replies: [String] = []
    }

    private func makePage(_ recorder: Recorder) -> SettingsDeveloperTokens {
        SettingsDeveloperTokens(
            cli: {
                recorder.cliCalls += 1
                if recorder.cliCalls == 1 {
                    return await withCheckedContinuation { continuation in
                        recorder.releaseFirstCLI = continuation
                    }
                }
                return Self.cliURL
            },
            runCLI: { _, _, _ in
                recorder.runCalls += 1
                let reply = recorder.replies.removeFirst()
                return (0, Data(reply.utf8), Data())
            })
    }

    private func holdFirstLookup(_ page: SettingsDeveloperTokens, recorder: Recorder) async -> Task<Void, Never> {
        let older = Task { await page.refresh() }
        for _ in 0..<100 where recorder.releaseFirstCLI == nil { await Task.yield() }
        #expect(recorder.releaseFirstCLI != nil)
        return older
    }

    @Test func anOlderUnavailableLookupCannotOverwriteANewerInvocation() async {
        let recorder = Recorder()
        recorder.replies = [#"{"ok":true,"tokens":[{"id":"new"}],"canManageTeamTokens":false}"#]
        let page = makePage(recorder)
        let older = await holdFirstLookup(page, recorder: recorder)

        let newer = Task { await page.refresh() }
        await newer.value
        #expect(page.state["tokens"]?.arrayValue?.first?["id"]?.stringValue == "new")

        recorder.releaseFirstCLI?.resume(returning: nil)
        await older.value
        #expect(page.state["tokens"]?.arrayValue?.first?["id"]?.stringValue == "new")
        #expect(recorder.runCalls == 1)
    }

    @Test func anOlderSuccessfulLookupCannotOverwriteANewerInvocation() async {
        let recorder = Recorder()
        recorder.replies = [
            #"{"ok":true,"tokens":[{"id":"new"}],"canManageTeamTokens":false}"#,
            #"{"ok":true,"tokens":[{"id":"old"}],"canManageTeamTokens":false}"#,
        ]
        let page = makePage(recorder)
        let older = await holdFirstLookup(page, recorder: recorder)

        let newer = Task { await page.refresh() }
        await newer.value
        recorder.releaseFirstCLI?.resume(returning: Self.cliURL)
        await older.value
        #expect(page.state["tokens"]?.arrayValue?.first?["id"]?.stringValue == "new")
        #expect(recorder.runCalls == 1)
    }
}
