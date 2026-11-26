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
        var releaseFirstCLI: CheckedContinuation<URL?, Never>?
        var replies = [
            #"{"ok":true,"tokens":[{"id":"new"}],"canManageTeamTokens":false}"#,
            #"{"ok":true,"tokens":[{"id":"old"}],"canManageTeamTokens":false}"#,
        ]
    }

    @Test func anOlderRefreshCannotOverwriteANewerInvocation() async {
        let recorder = Recorder()
        let page = SettingsDeveloperTokens(
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
                let reply = recorder.replies.removeFirst()
                return (0, Data(reply.utf8), Data())
            })

        let older = Task { await page.refresh() }
        for _ in 0..<100 where recorder.releaseFirstCLI == nil { await Task.yield() }
        #expect(recorder.releaseFirstCLI != nil)

        let newer = Task { await page.refresh() }
        await newer.value
        #expect(page.state["tokens"]?.arrayValue?.first?["id"]?.stringValue == "new")

        recorder.releaseFirstCLI?.resume(returning: Self.cliURL)
        await older.value
        #expect(page.state["tokens"]?.arrayValue?.first?["id"]?.stringValue == "new")
    }
}
