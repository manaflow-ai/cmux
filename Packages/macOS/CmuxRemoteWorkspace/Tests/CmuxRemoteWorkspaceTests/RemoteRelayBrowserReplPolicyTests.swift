import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// `browser.repl.*` evaluates arbitrary JavaScript that drives the local
/// user's browser tabs, reads their cookies, and reads and writes files under
/// a caller-chosen directory on the local Mac. A remote relay must never reach
/// it, with or without selectors that name the relay's own workspace.
@Suite("Remote relay denies the browser REPL")
struct RemoteRelayBrowserReplPolicyTests {
    private let workspace = UUID()

    @Test("REPL methods are denied for every parameter shape", arguments: [
        "browser.repl.eval", "browser.repl.reset", "browser.repl.list"
    ])
    func replMethodsAreDenied(method: String) throws {
        let attempts: [[String: Any]] = [
            [:],
            ["workspace_id": workspace.uuidString],
            ["code": "await tabs.open('https://example.com')", "cwd": "/tmp"],
            ["code": "console.log(1)", "caller_workspace_id": workspace.uuidString],
            ["code": "console.log(1)", "workspace_id": workspace.uuidString, "session": "s1"],
            ["session": "s1"],
        ]
        for params in attempts {
            let line = try JSONSerialization.data(withJSONObject: ["id": "r1", "method": method, "params": params])
            #expect(RemoteRelayCommandPolicy().evaluate(
                commandLine: line,
                workspaceAliases: [workspace: workspace],
                surfaceAliases: [:]
            ) != .allow)
        }
    }

    @Test("Capability discovery never advertises the REPL to a relay")
    func replIsNotDiscoverable() {
        let methods = RemoteRelayCommandPolicy().permittedMethods(from: [
            "system.ping", "browser.repl.eval", "browser.repl.reset", "browser.repl.list"
        ])
        #expect(methods == ["system.ping"])
    }
}
