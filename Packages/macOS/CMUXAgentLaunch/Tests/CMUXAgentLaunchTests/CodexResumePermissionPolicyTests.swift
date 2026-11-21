import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite
struct CodexResumePermissionPolicyTests {
    private let policy = CodexResumePermissionPolicy()
    private let evidence = ["-a", "never", "-s", "workspace-write", "-c", "sandbox_workspace_write.network_access=true"]

    /// Recovers each absent permission field while retaining explicit networking and avoiding duplicate sandbox flags.
    @Test("Approval, sandbox and network are recovered independently", arguments: [
        ["codex"], ["codex", "-s", "workspace-write"],
        ["codex", "-c", "sandbox_workspace_write.network_access=false"],
        ["codex", "--ask-for-approval=never"]
    ])
    func missingFields(arguments: [String]) {
        let launch = AgentLaunchCommand(launcher: "codex", arguments: arguments)
        let repaired = policy.repairing(launch, with: evidence)
        #expect(repaired.arguments.contains("never") || repaired.arguments.contains("--ask-for-approval=never"))
        #expect(repaired.arguments.contains("workspace-write"))
        #expect(repaired.arguments.contains("sandbox_workspace_write.network_access=\(arguments.contains("sandbox_workspace_write.network_access=false") ? "false" : "true")"))
        #expect(repaired.arguments.filter { $0 == "-s" }.count == 1)
    }

    /// Ensures argv ordering cannot let a config override defeat an explicit sandbox flag.
    @Test("Explicit sandbox flags outrank config regardless of ordering", arguments: [
        ["-s", "workspace-write", "-c", "sandbox_mode=\"read-only\""],
        ["-c", "sandbox_mode=\"read-only\"", "--sandbox=workspace-write"],
        ["-sworkspace-write", "--config=sandbox_mode='read-only'"],
        ["-s=workspace-write", "-csandbox_mode='read-only'"]
    ])
    func sandboxFlagPrecedence(arguments: [String]) {
        let launch = AgentLaunchCommand(launcher: "codex", arguments: ["codex"] + arguments)
        let repaired = policy.repairing(launch, with: evidence)
        #expect(repaired.arguments.suffix(2) == ["-c", "sandbox_workspace_write.network_access=true"])
        #expect(repaired.arguments.contains("never"))
    }

    /// Checks that complete policies request no transcript evidence and gain no additional arguments.
    @Test("Fully explicit fields skip transcript reads", arguments: [
        ["codex", "--yolo"], ["codex", "--full-auto", "-c", "sandbox_workspace_write={network_access=false}"],
        ["codex", "-a", "never", "-s", "read-only"],
        ["codex", "-a", "never", "-s", "workspace-write", "-c", "sandbox_workspace_write.network_access=false"]
    ])
    func completePolicyNeedsNoEvidence(arguments: [String]) {
        let launch = AgentLaunchCommand(launcher: "codex", arguments: arguments)
        #expect(!policy.requiresTranscriptEvidence(for: launch))
        #expect(policy.repairing(launch, with: evidence).arguments == arguments)
    }

    /// Keeps the workspace-write shortcut eligible for recovery until networking is specified.
    @Test("Workspace sandbox still needs a missing network field")
    func incompleteNetworkNeedsEvidence() {
        let launch = AgentLaunchCommand(launcher: "codex", arguments: ["codex", "--full-auto"])
        #expect(policy.requiresTranscriptEvidence(for: launch))
    }

    /// Preserves an explicit network setting while recovering the other permission fields.
    @Test("A parent network table stays authoritative")
    func parentTable() {
        let launch = AgentLaunchCommand(launcher: "codex", arguments: ["codex", "-c", "sandbox_workspace_write={network_access=false}"])
        let repaired = policy.repairing(launch, with: evidence)
        #expect(!repaired.arguments.contains("sandbox_workspace_write.network_access=true"))
        #expect(repaired.arguments.suffix(4) == ["-a", "never", "-s", "workspace-write"])
    }

    /// Treats bare and escaped roots-only keys consistently and ignores network-like text in nested values.
    @Test("A table without a network key still recovers recorded networking", arguments: [
        "{}", "{writable_roots=['/tmp/network_access']}",
        "{\"writable\\U0000005Froots\"=[]}",
        "{\"writable\\u005Froots\"=[]}",
        "{\"writable\\x5Froots\"=[]}",
        "{writable_roots=[\"/tmp/a,b=network_access\"]}",
        "{writable_roots=[], other={network_access=false}}"
    ])
    func parentTableWithoutNetwork(value: String) {
        let arguments = ["codex", "-c", "sandbox_workspace_write=\(value)"]
        let launch = AgentLaunchCommand(launcher: "codex", arguments: arguments)
        let repaired = policy.repairing(launch, with: evidence)
        #expect(repaired.arguments.prefix(arguments.count) == arguments[...])
        #expect(repaired.arguments.contains("sandbox_workspace_write.network_access=true"))
    }

    /// Preserves quoted network keys and conservatively retains unparseable explicit table overrides.
    @Test("Declared or unparseable table networking remains authoritative", arguments: [
        "{writable_roots=[], network_access=false}", "{'network_access'=false}",
        "{\"network_access\"=false}", "{\"network\\u005faccess\"=false}",
        "{\"network\\U0000005Faccess\"=false}",
        "{writable_roots=['unterminated}"
    ])
    func explicitTableNetwork(value: String) {
        let launch = AgentLaunchCommand(launcher: "codex", arguments: ["codex", "-c", "sandbox_workspace_write=\(value)"])
        #expect(!policy.repairing(launch, with: evidence).arguments.contains("sandbox_workspace_write.network_access=true"))
    }

    /// Prevents prompt tokens after the separator from masquerading as explicit permission flags.
    @Test("Options in a prompt after the separator are not explicit permissions")
    func optionTerminator() {
        let launch = AgentLaunchCommand(launcher: "codex", arguments: ["codex", "--", "--yolo"])
        #expect(!policy.hasExplicitPermissions(in: launch))
        #expect(policy.requiresTranscriptEvidence(for: launch))
    }

    /// Keeps repaired flags before the separator without modifying literal prompt content.
    @Test("Recovered options precede the prompt separator", arguments: [
        ["-a", "never", "-s", "workspace-write"], ["--yolo"]
    ])
    func recoveredOptionsPrecedePrompt(arguments: [String]) {
        let prompt = ["--", "--yolo", "two words", "literal $(false)"]
        let launch = AgentLaunchCommand(launcher: "codex", arguments: ["codex"] + prompt)
        #expect(policy.repairing(launch, with: arguments).arguments == ["codex"] + arguments + prompt)
    }

    /// Recovers approval from bypass evidence without replacing an explicit restrictive sandbox.
    @Test("Bypass evidence fills missing fields without overriding an explicit sandbox")
    func bypassEvidence() {
        let launch = AgentLaunchCommand(launcher: "codex", arguments: ["codex", "--sandbox=read-only"])
        #expect(policy.repairing(launch, with: ["--yolo"]).arguments == ["codex", "--sandbox=read-only", "-a", "never"])
    }

    /// Rejects number/string lookalikes for JSON Booleans and excludes records after the capture cutoff.
    @Test("Only recorded JSON Booleans become network settings", arguments: ["true", "false", "1", "0", "\"true\"", "null"])
    func strictNetworkBoolean(value: String) {
        let line = Data("{\"type\":\"turn_context\",\"timestamp\":\"2026-11-01T12:00:00.000Z\",\"payload\":{\"approval_policy\":\"never\",\"sandbox_policy\":{\"type\":\"workspace-write\",\"network_access\":\(value)}}}".utf8)
        let arguments = policy.permissionArguments(from: line, before: 2_000_000_000) ?? []
        #expect(arguments.prefix(4) == ["-a", "never", "-s", "workspace-write"])
        let network = arguments.filter { $0.hasPrefix("sandbox_workspace_write.network_access=") }
        #expect(network == (["true", "false"].contains(value) ? ["sandbox_workspace_write.network_access=\(value)"] : []))
        #expect(policy.permissionArguments(from: line, before: 0) == nil)
    }
}
