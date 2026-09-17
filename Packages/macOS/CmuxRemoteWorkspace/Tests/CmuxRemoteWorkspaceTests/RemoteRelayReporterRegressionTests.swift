import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("GHSA reporter selector regressions")
struct RemoteRelayReporterRegressionTests {
    private let owner = UUID()
    private let remoteSurface = UUID()
    private let localSurface = UUID()

    @Test("terminal_id cannot bypass ownership using an unrelated owned selector")
    func terminalAliasBypass() {
        let params: [String: Any] = [
            "preferred_workspace_id": owner.uuidString,
            "terminal_id": localSurface.uuidString,
            "text": "touch /tmp/pwned"
        ]
        #expect(decision("surface.send_text", params) != .allowed)
        #expect(decision("surface.send_key", params.merging(["key": "Enter"]) { _, new in new }) != .allowed)
    }

    @Test("an owned decoy does not authorize irrelevant routing", arguments: [
        "preferred_workspace_id", "target_surface_id", "tab_id", "target_terminal_id"
    ])
    func irrelevantRouting(key: String) {
        let params: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": remoteSurface.uuidString,
            key: localSurface.uuidString,
            "text": "echo scoped"
        ]
        #expect(decision("surface.send_text", params) != .allowed)
    }

    @Test("unknown methods remain denied even with owned selectors")
    func unknownMethod() {
        #expect(decision("future.execute", [
            "workspace_id": owner.uuidString,
            "surface_id": remoteSurface.uuidString
        ]) != .allowed)
    }

    @Test("unknown parameters cannot become future implicit selectors", arguments: ["target", "selector", "metadata"])
    func unknownParameters(key: String) throws {
        let params: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": remoteSurface.uuidString,
            "text": "echo scoped",
            key: ["id": localSurface.uuidString]
        ]
        #expect(decision("surface.send_text", params) != .allowed)
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "unknown-parameter", "method": "surface.send_text", "params": params
        ])
        #expect(RemoteRelayCommandPolicy().evaluate(commandLine: data,
            workspaceAliases: [:], surfaceAliases: [:]) != .allow)
    }

    @Test("container values cannot masquerade as exact terminal selectors")
    func malformedSelectorContainers() {
        let values: [Any] = [["id": remoteSurface.uuidString], [remoteSurface.uuidString], 17, NSNull()]
        for value in values {
            let params: [String: Any] = ["workspace_id": owner.uuidString, "terminal_id": value]
            #expect(decision("surface.read_selection", params) != .allowed)
        }
    }

    @Test("removing live ownership invalidates a previously authorized selector")
    func revokedOwnership() {
        let policy = RemoteRelayAuthorizationPolicy()
        let params: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": remoteSurface.uuidString,
            "text": "echo scoped"
        ]
        #expect(decision("surface.send_text", params) == .allowed)
        #expect(policy.validate(method: "surface.send_text", parameters: params,
            ownerWorkspaceID: owner, surfaceIDs: []) != .allowed)
    }

    @Test("remote hook bridge accepts only bounded hook-shaped requests")
    func hookBridgeCommandShape() throws {
        let base: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": remoteSurface.uuidString,
        ]
        let valid = base.merging([
            "arguments": ["claude", "stop"],
            "environment": [
                "CMUX_WORKSPACE_ID": owner.uuidString,
                "CMUX_SURFACE_ID": remoteSurface.uuidString,
                "SSH_TTY": "/dev/pts/7",
            ],
            "stdin_base64": Data("{}".utf8).base64EncodedString(),
        ]) { _, new in new }
        #expect(commandVerdict("hooks.invoke", valid) == .allow)

        let arbitraryEnvironment = valid.merging([
            "environment": ["LD_PRELOAD": "/tmp/inject.so"],
        ]) { _, new in new }
        #expect(commandVerdict("hooks.invoke", arbitraryEnvironment) != .allow)

        let installerInvocation = valid.merging([
            "arguments": ["setup", "--yes"],
        ]) { _, new in new }
        #expect(commandVerdict("hooks.invoke", installerInvocation) != .allow)

        let oversizedChunk = base.merging([
            "transfer_id": "0:00000000-0000-0000-0000-000000000001",
            "chunk_base64": Data(repeating: 0, count: 6 * 1_024 + 1).base64EncodedString(),
        ]) { _, new in new }
        #expect(commandVerdict("hooks.invoke.append", oversizedChunk) != .allow)
    }

    private func commandVerdict(
        _ method: String,
        _ params: [String: Any]
    ) -> RemoteRelayCommandPolicy.Verdict {
        let request: [String: Any] = [
            "id": "hook-policy",
            "method": method,
            "params": params,
        ]
        let data = try! JSONSerialization.data(withJSONObject: request)
        return RemoteRelayCommandPolicy().evaluate(
            commandLine: data,
            workspaceAliases: [:],
            surfaceAliases: [:]
        )
    }

    private func decision(_ method: String, _ params: [String: Any]) -> RemoteRelayAuthorizationPolicy.Decision {
        RemoteRelayAuthorizationPolicy().validate(method: method, parameters: params,
            ownerWorkspaceID: owner, surfaceIDs: [remoteSurface])
    }
}
