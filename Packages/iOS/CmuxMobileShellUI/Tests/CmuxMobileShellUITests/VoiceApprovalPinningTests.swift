import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileShellUI

/// The approval card and the eventual execution must act on the same object:
/// spoken workspace references are frozen to stable ids at card-creation
/// time, and ambiguous references never resolve to a guess.
@MainActor
@Suite("Voice approval pinning and workspace resolution")
struct VoiceApprovalPinningTests {
    private func workspace(_ id: String, _ name: String) -> MobileWorkspacePreview {
        MobileWorkspacePreview(id: .init(rawValue: id), name: name, terminals: [])
    }

    @Test("spoken names resolve by id, unique exact name, then unique substring")
    func resolutionOrder() {
        let workspaces = [
            workspace("ws-1", "api server"),
            workspace("ws-2", "frontend"),
            workspace("ws-3", "Frontend Tools"),
        ]
        #expect(
            VoiceOrchestratorToolExecutor.resolveWorkspace("ws-2", in: workspaces)?.name
                == "frontend"
        )
        #expect(
            VoiceOrchestratorToolExecutor.resolveWorkspace("API SERVER", in: workspaces)?.id.rawValue
                == "ws-1"
        )
        #expect(
            VoiceOrchestratorToolExecutor.resolveWorkspace("tools", in: workspaces)?.id.rawValue
                == "ws-3"
        )
    }

    @Test("ambiguous references fail closed")
    func ambiguityFailsClosed() {
        let duplicates = [
            workspace("ws-1", "api"),
            workspace("ws-2", "api"),
            workspace("ws-3", "api extras"),
        ]
        // Two exact-name matches: never guess.
        #expect(VoiceOrchestratorToolExecutor.resolveWorkspace("api", in: duplicates) == nil)
        // Substring matching three workspaces: never guess.
        #expect(VoiceOrchestratorToolExecutor.resolveWorkspace("a", in: duplicates) == nil)
        // An id still resolves exactly even when names collide.
        #expect(
            VoiceOrchestratorToolExecutor.resolveWorkspace("ws-2", in: duplicates)?.id.rawValue
                == "ws-2"
        )
        #expect(VoiceOrchestratorToolExecutor.resolveWorkspace("  ", in: duplicates) == nil)
    }

    @Test("close_workspace pins the spoken name to the workspace id")
    func closeWorkspacePinning() throws {
        let workspaces = [workspace("ws-9", "voice lab")]
        let pinned = VoiceOrchestratorToolExecutor.pinnedApprovalArguments(
            forTool: "close_workspace",
            argumentsJSON: #"{"workspace":"voice lab"}"#,
            workspaces: workspaces
        )
        #expect(pinned.target == "voice lab")
        let arguments = try #require(
            try JSONSerialization.jsonObject(
                with: Data(pinned.argumentsJSON.utf8)
            ) as? [String: Any]
        )
        #expect(arguments["workspace"] as? String == "ws-9")
    }

    @Test("type_in_terminal pins the id and carries the payload on the card")
    func typeInTerminalPinning() throws {
        let workspaces = [workspace("ws-9", "voice lab")]
        let pinned = VoiceOrchestratorToolExecutor.pinnedApprovalArguments(
            forTool: "type_in_terminal",
            argumentsJSON: #"{"workspace":"voice lab","text":"rm -rf build","press_return":true}"#,
            workspaces: workspaces
        )
        #expect(pinned.target == "voice lab: rm -rf build")
        let arguments = try #require(
            try JSONSerialization.jsonObject(
                with: Data(pinned.argumentsJSON.utf8)
            ) as? [String: Any]
        )
        #expect(arguments["workspace"] as? String == "ws-9")
        #expect(arguments["text"] as? String == "rm -rf build")
        #expect(arguments["press_return"] as? Bool == true)
    }

    @Test("unresolvable references pass through for the executor's error path")
    func unresolvablePassthrough() {
        let pinned = VoiceOrchestratorToolExecutor.pinnedApprovalArguments(
            forTool: "close_workspace",
            argumentsJSON: #"{"workspace":"nothing like this"}"#,
            workspaces: [workspace("ws-1", "api")]
        )
        #expect(pinned.argumentsJSON == #"{"workspace":"nothing like this"}"#)
        #expect(pinned.target == "nothing like this")

        let invalid = VoiceOrchestratorToolExecutor.pinnedApprovalArguments(
            forTool: "close_workspace",
            argumentsJSON: "not json",
            workspaces: []
        )
        #expect(invalid.argumentsJSON == "not json")
        #expect(invalid.target == nil)
    }
}
