import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite
struct CodexResumePermissionPolicyTests {
    private let policy = CodexResumePermissionPolicy()
    private let evidence = ["-a", "never", "-s", "workspace-write", "-c", "sandbox_workspace_write.network_access=true"]

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

    @Test("Workspace sandbox still needs a missing network field")
    func incompleteNetworkNeedsEvidence() {
        let launch = AgentLaunchCommand(launcher: "codex", arguments: ["codex", "--full-auto"])
        #expect(policy.requiresTranscriptEvidence(for: launch))
    }

    @Test("A parent network table stays authoritative")
    func parentTable() {
        let launch = AgentLaunchCommand(launcher: "codex", arguments: ["codex", "-c", "sandbox_workspace_write={network_access=false}"])
        let repaired = policy.repairing(launch, with: evidence)
        #expect(!repaired.arguments.contains("sandbox_workspace_write.network_access=true"))
        #expect(repaired.arguments.suffix(4) == ["-a", "never", "-s", "workspace-write"])
    }

    @Test("Options in a prompt after the separator are not explicit permissions")
    func optionTerminator() {
        let launch = AgentLaunchCommand(launcher: "codex", arguments: ["codex", "--", "--yolo"])
        #expect(!policy.hasExplicitPermissions(in: launch))
        #expect(policy.requiresTranscriptEvidence(for: launch))
    }

    @Test("Recovered options precede the prompt separator", arguments: [
        ["-a", "never", "-s", "workspace-write"], ["--yolo"]
    ])
    func recoveredOptionsPrecedePrompt(arguments: [String]) {
        let prompt = ["--", "--yolo", "two words", "literal $(false)"]
        let launch = AgentLaunchCommand(launcher: "codex", arguments: ["codex"] + prompt)
        #expect(policy.repairing(launch, with: arguments).arguments == ["codex"] + arguments + prompt)
    }

    @Test("Bypass evidence fills missing fields without overriding an explicit sandbox")
    func bypassEvidence() {
        let launch = AgentLaunchCommand(launcher: "codex", arguments: ["codex", "--sandbox=read-only"])
        #expect(policy.repairing(launch, with: ["--yolo"]).arguments == ["codex", "--sandbox=read-only", "-a", "never"])
    }

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
