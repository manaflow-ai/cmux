import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// `chief.*` reads and writes the user's local Chief conversations and can
/// start a Chief turn, which runs commands on this Mac. A remote session has
/// no product need for any of it, so the family stays off the relay
/// allowlist, even with a workspace the session owns.
@Suite("Remote relay Chief methods")
struct RemoteRelayChiefPolicyTests {
    static let methods = [
        "chief.open", "chief.send", "chief.status", "chief.conversations", "chief.read", "chief.mark_read", "chief.stop", "chief.approve", "chief.answer",
        "chief.debug",
    ]

    @Test("chief.* is never forwarded, even for an owned workspace", arguments: methods)
    func chiefMethodIsDenied(method: String) throws {
        let workspace = UUID()
        let request: [String: Any] = [
            "id": "chief",
            "method": method,
            "params": ["workspace_id": workspace.uuidString, "text": "hello", "from": "remote"],
        ]
        let line = try JSONSerialization.data(withJSONObject: request)
        let verdict = RemoteRelayCommandPolicy().evaluate(
            commandLine: line,
            workspaceAliases: [workspace: workspace],
            surfaceAliases: [:]
        )
        guard case .deny = verdict else {
            Issue.record("\(method) was allowed through the relay")
            return
        }
        #expect(RemoteRelayCommandPolicy().permittedMethods(from: [method]).isEmpty)
    }
}
