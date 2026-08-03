#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxVoice
import Foundation

/// Bridges GPT's constrained tools to the live, multi-Mac mobile shell.
@MainActor
final class MobileShellVoiceToolExecutor: RealtimeVoiceToolExecuting {
    typealias TargetProvider = @MainActor @Sendable () -> [MobileShellVoiceTarget]
    typealias SubmitProvider = @MainActor @Sendable () -> Bool
    typealias Sender = @MainActor @Sendable (
        String,
        Bool,
        MobileWorkspacePreview.ID,
        MobileTerminalPreview.ID
    ) async throws -> MobileShellVoiceDelivery

    private struct TargetKey: Hashable {
        let workspaceID: MobileWorkspacePreview.ID
        let terminalID: MobileTerminalPreview.ID
    }

    private let targetProvider: TargetProvider
    private let submitProvider: SubmitProvider
    private let sender: Sender
    private var opaqueIDByKey: [TargetKey: String] = [:]
    private var targetByOpaqueID: [String: MobileShellVoiceTarget] = [:]
    private var nextOpaqueID = 1

    init(
        store: CMUXMobileShellStore,
        voiceSettings: VoiceSettingsStore
    ) {
        self.targetProvider = {
            store.workspaces.flatMap { workspace in
                let supportsTargeting = store.supportsGPTVoiceTarget(
                    workspaceID: workspace.id
                )
                let computerName = workspace.macDisplayName
                    ?? L10n.string(
                        "mobile.voiceMode.computer",
                        defaultValue: "Computer"
                    )
                return workspace.terminals.map { terminal in
                    MobileShellVoiceTarget(
                        workspaceID: workspace.id,
                        terminalID: terminal.id,
                        computerName: computerName,
                        workspaceName: workspace.name,
                        terminalName: terminal.name,
                        currentDirectory: terminal.currentDirectory
                            ?? workspace.currentDirectory,
                        isFocused: terminal.isFocused,
                        isReady: supportsTargeting && terminal.isReady
                    )
                }
            }
        }
        self.submitProvider = { voiceSettings.voiceModeAutoSubmit }
        self.sender = { text, submit, workspaceID, terminalID in
            let response = try await store.sendVoiceInput(
                text: text,
                submit: submit,
                workspaceID: workspaceID,
                terminalID: terminalID
            )
            return MobileShellVoiceDelivery(
                targetTitle: response.surfaceTitle
                    ?? L10n.string(
                        "mobile.voiceMode.terminal",
                        defaultValue: "Terminal"
                    ),
                queued: response.queued
            )
        }
    }

    init(
        targetProvider: @escaping TargetProvider,
        submitProvider: @escaping SubmitProvider,
        sender: @escaping Sender
    ) {
        self.targetProvider = targetProvider
        self.submitProvider = submitProvider
        self.sender = sender
    }

    func execute(
        _ call: RealtimeVoiceToolCall,
        latestUserTranscript: String?
    ) async -> RealtimeVoiceToolResult {
        switch call {
        case .listTerminals:
            return listTerminals()
        case .sendLatestUtterance(let targetIDs):
            return await sendLatestUtterance(
                targetIDs: targetIDs,
                transcript: latestUserTranscript
            )
        }
    }

    private func listTerminals() -> RealtimeVoiceToolResult {
        let allTargets = targetProvider()
        let targets = Array(allTargets.prefix(256))
        targetByOpaqueID.removeAll(keepingCapacity: true)
        let payload = targets.map { target -> [String: Any] in
            let key = TargetKey(
                workspaceID: target.workspaceID,
                terminalID: target.terminalID
            )
            let opaqueID: String
            if let existing = opaqueIDByKey[key] {
                opaqueID = existing
            } else {
                opaqueID = "terminal-\(nextOpaqueID)"
                nextOpaqueID += 1
                opaqueIDByKey[key] = opaqueID
            }
            targetByOpaqueID[opaqueID] = target
            var item: [String: Any] = [
                "id": opaqueID,
                "computer": Self.boundedMetadata(
                    target.computerName,
                    maxCharacters: 128
                ),
                "workspace": Self.boundedMetadata(
                    target.workspaceName,
                    maxCharacters: 256
                ),
                "terminal": Self.boundedMetadata(
                    target.terminalName,
                    maxCharacters: 256
                ),
                "focused": target.isFocused,
                "ready": target.isReady,
            ]
            if let currentDirectory = target.currentDirectory {
                item["current_directory"] = Self.boundedMetadata(
                    currentDirectory,
                    maxCharacters: 512
                )
            }
            return item
        }
        return RealtimeVoiceToolResult(
            output: Self.json([
                "ok": true,
                "targets": payload,
                "truncated": allTargets.count > targets.count,
            ])
        )
    }

    private func sendLatestUtterance(
        targetIDs: [String],
        transcript: String?
    ) async -> RealtimeVoiceToolResult {
        guard let transcript,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return RealtimeVoiceToolResult(
                output: Self.json([
                    "ok": false,
                    "error": "transcript_unavailable",
                ])
            )
        }

        let submit = submitProvider()
        var delivered = [[String: Any]]()
        var failed = [[String: Any]]()
        for targetID in targetIDs {
            guard let target = targetByOpaqueID[targetID], target.isReady else {
                failed.append([
                    "id": targetID,
                    "error": "target_unavailable",
                ])
                continue
            }
            do {
                let result = try await sender(
                    transcript,
                    submit,
                    target.workspaceID,
                    target.terminalID
                )
                delivered.append([
                    "id": targetID,
                    "terminal": result.targetTitle,
                    "queued": result.queued,
                ])
            } catch {
                failed.append([
                    "id": targetID,
                    "error": "delivery_failed",
                ])
            }
        }

        return RealtimeVoiceToolResult(
            output: Self.json([
                "ok": !delivered.isEmpty && failed.isEmpty,
                "submitted": submit,
                "delivered": delivered,
                "failed": failed,
            ]),
            deliveredLatestUtterance: !delivered.isEmpty
        )
    }

    private static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
              ),
              let value = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"serialization_failed"}"#
        }
        return value
    }

    private static func boundedMetadata(
        _ value: String,
        maxCharacters: Int
    ) -> String {
        let visible = value.filter { character in
            !character.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
        }
        return String(visible.prefix(maxCharacters))
    }
}
#endif
