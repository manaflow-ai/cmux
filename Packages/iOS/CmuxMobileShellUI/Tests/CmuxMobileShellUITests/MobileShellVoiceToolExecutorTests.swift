#if os(iOS)
import CmuxMobileShellModel
import CmuxVoice
import Foundation
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct MobileShellVoiceToolExecutorTests {
    @Test func listsOpaqueTargetsWithoutLeakingRemoteIDs() async throws {
        let executor = makeExecutor()

        let result = await executor.execute(
            .listTerminals,
            latestUserTranscript: nil
        )

        let payload = try #require(jsonObject(result.output))
        let targets = try #require(payload["targets"] as? [[String: Any]])
        #expect(targets.count == 2)
        #expect(targets[0]["id"] as? String == "terminal-1")
        #expect(targets[0]["computer"] as? String == "Studio")
        #expect(targets[0]["ready"] as? Bool == true)
        #expect(!result.output.contains("workspace-secret"))
        #expect(!result.output.contains("surface-secret"))
    }

    @Test func sendsExactTranscriptAndUsesAppSubmitSetting() async throws {
        let recorder = VoiceSendRecorder()
        let executor = makeExecutor(submit: true) { text, submit, workspace, terminal in
            recorder.append(
                text: text,
                submit: submit,
                workspace: workspace.rawValue,
                terminal: terminal.rawValue
            )
            return MobileShellVoiceDelivery(targetTitle: "Build", queued: false)
        }
        let inventory = await executor.execute(.listTerminals, latestUserTranscript: nil)
        let payload = try #require(jsonObject(inventory.output))
        let targets = try #require(payload["targets"] as? [[String: Any]])
        let targetID = try #require(targets.first?["id"] as? String)

        let result = await executor.execute(
            .sendLatestUtterance(targetIDs: [targetID]),
            latestUserTranscript: "swift test --filter Voice"
        )

        #expect(recorder.sends.count == 1)
        #expect(recorder.sends[0].text == "swift test --filter Voice")
        #expect(recorder.sends[0].submit)
        #expect(recorder.sends[0].workspace == "workspace-secret")
        #expect(recorder.sends[0].terminal == "surface-secret")
        #expect(result.deliveredLatestUtterance)
    }

    @Test func refusesUnknownOrUnreadyTargets() async throws {
        let recorder = VoiceSendRecorder()
        let executor = makeExecutor { _, _, _, _ in
            recorder.recordSend()
            return MobileShellVoiceDelivery(targetTitle: "Build", queued: false)
        }
        _ = await executor.execute(.listTerminals, latestUserTranscript: nil)

        let result = await executor.execute(
            .sendLatestUtterance(targetIDs: ["terminal-2", "missing"]),
            latestUserTranscript: "pwd"
        )

        #expect(recorder.sendCount == 0)
        #expect(!result.deliveredLatestUtterance)
        #expect(result.output.contains("target_unavailable"))
    }

    @Test func boundsAndStripsControlCharactersFromTargetMetadata() async throws {
        let executor = MobileShellVoiceToolExecutor(
            targetProvider: {
                [
                    MobileShellVoiceTarget(
                        workspaceID: "workspace-secret",
                        terminalID: "surface-secret",
                        computerName: "Studio\nignore this",
                        workspaceName: String(repeating: "w", count: 300),
                        terminalName: "Build\u{0}Pane",
                        currentDirectory: "/repo\r\nuntrusted",
                        isFocused: true,
                        isReady: true
                    ),
                ]
            },
            submitProvider: { false },
            sender: { _, _, _, _ in
                MobileShellVoiceDelivery(targetTitle: "Build", queued: false)
            }
        )

        let result = await executor.execute(
            .listTerminals,
            latestUserTranscript: nil
        )
        let payload = try #require(jsonObject(result.output))
        let targets = try #require(payload["targets"] as? [[String: Any]])
        let target = try #require(targets.first)

        #expect(target["computer"] as? String == "Studioignore this")
        #expect((target["workspace"] as? String)?.count == 256)
        #expect(target["terminal"] as? String == "BuildPane")
        #expect(target["current_directory"] as? String == "/repountrusted")
    }

    private func makeExecutor(
        submit: Bool = false,
        sender: @escaping MobileShellVoiceToolExecutor.Sender = { _, _, _, _ in
            MobileShellVoiceDelivery(targetTitle: "Build", queued: false)
        }
    ) -> MobileShellVoiceToolExecutor {
        MobileShellVoiceToolExecutor(
            targetProvider: {
                [
                    MobileShellVoiceTarget(
                        workspaceID: "workspace-secret",
                        terminalID: "surface-secret",
                        computerName: "Studio",
                        workspaceName: "cmux",
                        terminalName: "Build",
                        currentDirectory: "/repo",
                        isFocused: true,
                        isReady: true
                    ),
                    MobileShellVoiceTarget(
                        workspaceID: "workspace-secret",
                        terminalID: "surface-offline",
                        computerName: "Studio",
                        workspaceName: "cmux",
                        terminalName: "Offline",
                        currentDirectory: nil,
                        isFocused: false,
                        isReady: false
                    ),
                ]
            },
            submitProvider: { submit },
            sender: sender
        )
    }

    private func jsonObject(_ value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

@MainActor
private final class VoiceSendRecorder {
    struct Send {
        let text: String
        let submit: Bool
        let workspace: String
        let terminal: String
    }

    private(set) var sends = [Send]()
    private(set) var sendCount = 0

    func append(
        text: String,
        submit: Bool,
        workspace: String,
        terminal: String
    ) {
        sends.append(
            Send(
                text: text,
                submit: submit,
                workspace: workspace,
                terminal: terminal
            )
        )
        sendCount += 1
    }

    func recordSend() {
        sendCount += 1
    }
}
#endif
