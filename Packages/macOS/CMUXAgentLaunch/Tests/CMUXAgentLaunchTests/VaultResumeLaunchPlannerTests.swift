import CMUXAgentLaunch
import Foundation
import Testing

@Suite("Vault resume launch planner")
struct VaultResumeLaunchPlannerTests {
    private let planner = VaultResumeLaunchPlanner()

    @Test(arguments: [
        ("claude", VaultResumeLaunchRequest.AgentProfile.claude(
            model: "sonnet",
            permissionMode: "acceptEdits",
            configDirectory: "/tmp/claude"
        )),
        ("codex", .codex(
            model: "gpt-5.5",
            approvalPolicy: "never",
            sandboxMode: "disabled",
            effort: "high"
        )),
        ("grok", .grok(
            model: "grok-4",
            permissionMode: "auto",
            sandboxMode: "danger-full-access",
            grokHome: "/tmp/grok"
        )),
        ("opencode", .opencode(providerModel: "anthropic/sonnet", agentName: "build")),
        ("rovodev", .rovodev),
        ("hermes-agent", .hermesAgent(source: "tui", model: "gpt-5.5", hermesHome: "/tmp/hermes")),
    ])
    func builtInProfilesProduceRestoreSelectors(
        _ kind: String,
        _ profile: VaultResumeLaunchRequest.AgentProfile
    ) throws {
        let request = VaultResumeLaunchRequest(
            kind: kind,
            sessionID: "vault-\(kind)-session",
            workingDirectory: "/tmp/project",
            profile: profile,
            legacyCommand: "legacy --resume vault-\(kind)-session"
        )

        let plan = try #require(planner.plan(for: request))
        let snapshot = try #require(plan.structuredSnapshot)

        #expect(plan.strategy == .restoreVerb)
        #expect(
            plan.startupInput(for: .posix)
                == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore \(kind) vault-\(kind)-session\n"
        )
        #expect(snapshot.kind == kind)
        #expect(snapshot.workingDirectory == "/tmp/project")
        #expect(!snapshot.preparedResumeArguments.isEmpty)
    }

    @Test("Rovo Dev receives exactly one restore selector")
    func rovodevUsesOneRestoreOption() throws {
        let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
            kind: "rovodev",
            sessionID: "rovo-session",
            workingDirectory: "/tmp/project",
            profile: .rovodev,
            legacyCommand: nil
        )))
        let arguments = try #require(plan.structuredSnapshot?.preparedResumeArguments)

        #expect(arguments == ["acli", "rovodev", "run", "--restore", "rovo-session"])
    }

    @Test("Codex policy values are trimmed before they become flags")
    func codexPolicyValuesAreTrimmed() {
        let planner = VaultResumeLaunchPlanner()

        #expect(
            planner.codexApprovalSandboxArgumentTokens(
                approvalPolicy: " never ",
                sandboxMode: " disabled "
            ) == ["--dangerously-bypass-approvals-and-sandbox"]
        )
        #expect(
            planner.codexApprovalSandboxArgumentTokens(
                approvalPolicy: "   ",
                sandboxMode: " read-only "
            ) == ["-s", "read-only"]
        )
        #expect(
            planner.codexApprovalSandboxArgumentTokens(
                approvalPolicy: "on-failure",
                sandboxMode: nil
            ) == []
        )
    }

    @Test(arguments: ["pi", "omp", "campfire", "antigravity", "grok", "kimi"])
    func registeredBuiltInProfilesProduceRestoreSelectors(_ kind: String) throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: kind,
            defaultExecutable: kind == "antigravity" ? "agy" : kind,
            resumeCommand: "{{executable}} --session {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: kind
        )
        let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
            kind: kind,
            sessionID: "registered-\(kind)-session",
            workingDirectory: "/tmp/project",
            profile: .registered(registration),
            legacyCommand: nil
        )))
        let snapshot = try #require(plan.structuredSnapshot)

        #expect(plan.strategy == .restoreVerb)
        #expect(snapshot.kind == kind)
        #expect(snapshot.preparedResumeArguments.contains("registered-\(kind)-session"))
    }

    @Test("A cwd-prefixed env registration promotes environment into the record")
    func cwdPrefixedEnvironmentIsStructured() throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "grok",
            defaultExecutable: "grok",
            resumeCommand: "cd -- '/tmp/project' && env GROK_HOME='/tmp/grok profile' grok -r {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
            kind: "grok",
            sessionID: "grok-session",
            workingDirectory: "/tmp/project",
            profile: .registered(registration),
            legacyCommand: nil
        )))
        let snapshot = try #require(plan.structuredSnapshot)

        #expect(snapshot.environment["GROK_HOME"] == "/tmp/grok profile")
        #expect(snapshot.registration?.resumeCommand == "grok -r {{sessionId}}")
        #expect(snapshot.preparedResumeArguments == ["grok", "-r", "grok-session"])
    }

    @Test("A later env after a setup chain stays compatibility-only")
    func laterEnvironmentCommandIsNotTruncatedIntoTheRecord() throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "setup-agent",
            defaultExecutable: "setup-agent",
            resumeCommand: "cd -- '/tmp/project' && setup-agent-prepare && env GROK_HOME='/tmp/grok' setup-agent --session {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
            kind: "setup-agent",
            sessionID: "setup-session",
            workingDirectory: "/tmp/project",
            profile: .registered(registration),
            legacyCommand: "setup-agent --session setup-session"
        )))

        #expect(plan.strategy == .legacyCommand)
        #expect(plan.legacyFallbackReason == .unrepresentableRegistration)
        #expect(plan.structuredSnapshot == nil)
    }

    @Test("Registration paths remain byte-for-byte identical")
    func registrationEnvironmentDoesNotMigratePaths() throws {
        let exactValue = "~/.subrouter/codex/claude/account one"
        let registration = VaultResumeLaunchRequest.Registration(
            id: "my-agent",
            defaultExecutable: "my-agent",
            resumeCommand: "env CLAUDE_CONFIG_DIR='\(exactValue)' my-agent --session {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
            kind: "my-agent",
            sessionID: "custom-session",
            workingDirectory: "/tmp/project",
            profile: .registered(registration),
            legacyCommand: nil
        )))

        #expect(plan.structuredSnapshot?.environment["CLAUDE_CONFIG_DIR"] == exactValue)
    }

    @Test("Registration templates fail closed without an executable")
    func registrationTemplateRequiresExecutable() throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "identity-only",
            defaultExecutable: "   ",
            resumeCommand: "{{executable}} --session {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
            kind: "identity-only",
            sessionID: "identity-session",
            workingDirectory: nil,
            profile: .registered(registration),
            legacyCommand: "identity-only --session identity-session"
        )))

        #expect(plan.strategy == .legacyCommand)
        #expect(plan.legacyFallbackReason == .unavailableStructuredArguments)
    }

    @Test("Empty quoted registration arguments fail closed")
    func emptyQuotedRegistrationArgumentUsesCompatibility() throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "profile-agent",
            defaultExecutable: "profile-agent",
            resumeCommand: "{{executable}} --profile \"\" --session {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
            kind: "profile-agent",
            sessionID: "profile-session",
            workingDirectory: nil,
            profile: .registered(registration),
            legacyCommand: "profile-agent --profile '' --session profile-session"
        )))

        #expect(plan.strategy == .legacyCommand)
        #expect(plan.legacyFallbackReason == .unavailableStructuredArguments)
    }

    @Test("Shell operators stay on the compatibility path")
    func shellOperatorRegistrationUsesCompatibility() throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "setup-agent",
            defaultExecutable: "setup-agent",
            resumeCommand: "{{executable}} --session {{sessionId}} && echo done",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
            kind: "setup-agent",
            sessionID: "setup-session",
            workingDirectory: nil,
            profile: .registered(registration),
            legacyCommand: "setup-agent --session setup-session && echo done"
        )))

        #expect(plan.strategy == .legacyCommand)
        #expect(plan.legacyFallbackReason == .unavailableStructuredArguments)
    }

    @Test("Shell expansion stays on the compatibility path")
    func shellExpansionRegistrationUsesCompatibility() throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "expanding-agent",
            defaultExecutable: "expanding-agent",
            resumeCommand: "{{executable}} --profile \"$(runtime-home)\" --session {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
            kind: "expanding-agent",
            sessionID: "expanding-session",
            workingDirectory: nil,
            profile: .registered(registration),
            legacyCommand: "expanding-agent --profile \"$(runtime-home)\" --session expanding-session"
        )))

        #expect(plan.strategy == .legacyCommand)
        #expect(plan.legacyFallbackReason == .unavailableStructuredArguments)
    }

    @Test("Unknown and unterminated placeholders use compatibility")
    func invalidTemplatePlaceholdersUseCompatibility() throws {
        for template in [
            "path-agent --session {{unknown}}",
            "path-agent --session {{sessionId",
        ] {
            let registration = VaultResumeLaunchRequest.Registration(
                id: "path-agent",
                defaultExecutable: "path-agent",
                resumeCommand: template,
                workingDirectoryPolicy: .preserve,
                sessionDirectory: nil,
                registeredResumeKind: nil
            )
            let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
                kind: "path-agent",
                sessionID: "path-session",
                workingDirectory: nil,
                profile: .registered(registration),
                legacyCommand: "path-agent --session path-session"
            )))

            #expect(plan.strategy == .legacyCommand)
            #expect(plan.legacyFallbackReason == .unavailableStructuredArguments)
        }
    }

    @Test("Single-quoted template backslashes remain literal")
    func singleQuotedBackslashIsPreserved() throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "path-agent",
            defaultExecutable: "path-agent",
            resumeCommand: "{{executable}} --path 'a\\b' --session {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
            kind: "path-agent",
            sessionID: "path-session",
            workingDirectory: nil,
            profile: .registered(registration),
            legacyCommand: nil
        )))

        #expect(
            plan.structuredSnapshot?.preparedResumeArguments
                == ["path-agent", "--path", "a\\b", "--session", "path-session"]
        )
    }

    @Test("Double-quoted non-escapable backslashes remain literal")
    func doubleQuotedBackslashIsPreserved() throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "path-agent",
            defaultExecutable: "path-agent",
            resumeCommand: "{{executable}} --path \"a\\b\" --session {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
            kind: "path-agent",
            sessionID: "path-session",
            workingDirectory: nil,
            profile: .registered(registration),
            legacyCommand: nil
        )))

        #expect(
            plan.structuredSnapshot?.preparedResumeArguments
                == ["path-agent", "--path", "a\\b", "--session", "path-session"]
        )
    }

    @Test("Unicode printf environment values are decoded without executing shell text")
    func unicodeEnvironmentValueIsDecoded() throws {
        let grokHome = "/tmp/グロク profile"
        let encoded = grokHome.utf8
            .map { String(format: #"\%03o"#, Int($0)) }
            .joined()
        let registration = VaultResumeLaunchRequest.Registration(
            id: "grok",
            defaultExecutable: "grok",
            resumeCommand: "env GROK_HOME=\"$(printf '\(encoded)')\" grok -r {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
            kind: "grok",
            sessionID: "unicode-session",
            workingDirectory: "/tmp/project",
            profile: .registered(registration),
            legacyCommand: nil
        )))

        #expect(plan.structuredSnapshot?.environment["GROK_HOME"] == grokHome)
    }

    @Test("Dynamic environment prefixes are explicit compatibility")
    func dynamicEnvironmentUsesCompatibility() throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "dynamic-agent",
            defaultExecutable: "dynamic-agent",
            resumeCommand: "env GROK_HOME=$(runtime-home) dynamic-agent --session {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let plan = try #require(planner.plan(for: VaultResumeLaunchRequest(
            kind: "dynamic-agent",
            sessionID: "dynamic-session",
            workingDirectory: nil,
            profile: .registered(registration),
            legacyCommand: "dynamic-agent --session dynamic-session"
        )))

        #expect(plan.strategy == .legacyCommand)
        #expect(plan.legacyFallbackReason == .unrepresentableRegistration)
        #expect(plan.structuredSnapshot == nil)
    }

    @Test("Compatibility input is bounded in every supported dialect")
    func compatibilityInputIsBoundedInEveryDialect() throws {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "bad kind",
            defaultExecutable: "legacy-agent",
            resumeCommand: "legacy-agent --session {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let request = VaultResumeLaunchRequest(
            kind: "bad kind",
            sessionID: "legacy-session",
            workingDirectory: nil,
            profile: .registered(registration),
            legacyCommand: "legacy-agent " + String(repeating: "x", count: 880)
        )

        #expect(planner.plan(for: request) == nil)
    }

    @Test("Compatibility input rejects terminal controls")
    func compatibilityInputRejectsControls() {
        let registration = VaultResumeLaunchRequest.Registration(
            id: "bad kind",
            defaultExecutable: "legacy-agent",
            resumeCommand: "legacy-agent --session {{sessionId}}",
            workingDirectoryPolicy: .preserve,
            sessionDirectory: nil,
            registeredResumeKind: nil
        )
        let request = VaultResumeLaunchRequest(
            kind: "bad kind",
            sessionID: "legacy-session",
            workingDirectory: nil,
            profile: .registered(registration),
            legacyCommand: "legacy-agent\u{1B}[31m"
        )

        #expect(planner.plan(for: request) == nil)
    }
}
