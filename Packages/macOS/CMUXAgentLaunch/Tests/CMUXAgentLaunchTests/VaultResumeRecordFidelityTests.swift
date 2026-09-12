import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Vault restore record fidelity")
struct VaultResumeRecordFidelityTests {
    @Test(arguments: [
        "{{executable}} --continue",
        "{{executable}} --cwd {{cwd}}",
        "{{executable}} --session hardcoded-session",
    ])
    func templatesWithoutSessionPlaceholdersRemainCompatibilityOnly(_ template: String) throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "custom-agent",
            defaultExecutable: "custom-agent",
            resumeCommand: template,
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let plan = try #require(VaultResumeLaunchPlanner().plan(for: VaultResumeLaunchRequest(
            kind: "custom-agent",
            sessionID: "indexed-session",
            workingDirectory: "/tmp/project",
            profile: .registered(registration, launchCommand: nil),
            legacyCommand: "custom-agent --continue"
        )))

        #expect(plan.strategy == .legacyCommand)
        #expect(plan.structuredSnapshot == nil)
        #expect(plan.legacyFallbackReason == .unavailableStructuredArguments)
    }

    @Test(arguments: [
        nil,
        [:],
        ["SECRET_TOKEN": "must-not-persist"],
        ["CLAUDE_CONFIG_DIR": "/tmp/captured-account"],
        ["GROK_HOME": "/tmp/captured-grok"],
    ] as [[String: String]?])
    func capturedEnvironmentPreservesRegistrationAssignments(
        _ capturedEnvironment: [String: String]?
    ) throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "custom-agent",
            defaultExecutable: "custom-agent",
            resumeCommand: "env GROK_HOME=/tmp/template-grok CLAUDE_CONFIG_DIR=/tmp/template-account {{executable}} --session {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let capturedLaunch = AgentLaunchCommand(
            arguments: ["custom-agent"],
            workingDirectory: "/tmp/project",
            environment: capturedEnvironment,
            source: "vault"
        )
        let plan = try #require(VaultResumeLaunchPlanner().plan(for: VaultResumeLaunchRequest(
            kind: "custom-agent",
            sessionID: "environment-session",
            workingDirectory: "/tmp/project",
            profile: .registered(registration, launchCommand: capturedLaunch),
            legacyCommand: nil
        )))
        let snapshot = try #require(plan.structuredSnapshot)

        #expect(plan.strategy == .restoreVerb)
        #expect(snapshot.environment["GROK_HOME"] == (capturedEnvironment?["GROK_HOME"] ?? "/tmp/template-grok"))
        #expect(snapshot.environment["CLAUDE_CONFIG_DIR"] == (capturedEnvironment?["CLAUDE_CONFIG_DIR"] ?? "/tmp/template-account"))
        #expect(snapshot.environment["SECRET_TOKEN"] == nil)
    }

    @Test(arguments: [" padded ", "/tmp/a b ", " prefix", "suffix "])
    func quotedArgumentsMatchTheRestoreRenderer(_ argument: String) throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "custom-agent",
            defaultExecutable: "custom-agent",
            resumeCommand: "{{executable}} --label '\(argument)' --session {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let plan = try #require(VaultResumeLaunchPlanner().plan(for: VaultResumeLaunchRequest(
            kind: "custom-agent",
            sessionID: "quoted-session",
            workingDirectory: "/tmp/project",
            profile: .registered(registration, launchCommand: nil),
            legacyCommand: nil
        )))
        let snapshot = try #require(plan.structuredSnapshot)
        let restoreArguments = try #require(AgentLaunchTemplateRenderer().arguments(
            template: registration.resumeCommand,
            executable: "custom-agent",
            sessionID: "quoted-session",
            workingDirectory: "/tmp/project",
            sessionDirectory: nil
        ))

        #expect(snapshot.preparedResumeArguments == ["custom-agent", "--label", argument, "--session", "quoted-session"])
        #expect(snapshot.preparedResumeArguments == restoreArguments)
    }
}
