@testable import CmuxNextAgentIntegrations
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

@MainActor struct SettingsDeveloperTokensTests {
    nonisolated static let cliURL = URL(fileURLWithPath: "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux")

    /// The first lookup can be held until a later refresh has completed.
    nonisolated final class Recorder: @unchecked Sendable {
        var cliCalls = 0
        var runCalls = 0
        var releaseFirstCLI: CheckedContinuation<URL?, Never>?
        var replies: [String] = []
    }

    private func page(_ recorder: Recorder) -> SettingsDeveloperTokens {
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
        let page = page(recorder)
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
        let page = page(recorder)
        let older = await holdFirstLookup(page, recorder: recorder)

        let newer = Task { await page.refresh() }
        await newer.value
        recorder.releaseFirstCLI?.resume(returning: Self.cliURL)
        await older.value
        #expect(page.state["tokens"]?.arrayValue?.first?["id"]?.stringValue == "new")
        #expect(recorder.runCalls == 2)
    }
}
