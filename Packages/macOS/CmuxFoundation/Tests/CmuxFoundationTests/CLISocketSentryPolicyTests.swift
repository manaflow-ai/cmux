import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct CLISocketSentryPolicyTests {
    @Test(arguments: ["seatbelt", "read-only", "workspace-write"])
    func recognizesRestrictedCodexSandbox(_ value: String) {
        #expect(CLISocketSentryPolicy(
            environment: ["CODEX_SANDBOX": value]
        ).allowsSandboxPolicyDenial)
    }

    @Test(arguments: ["danger-full-access", "disabled", "none", "off", "unrestricted", "future-mode", " "])
    func keepsPolicyDenialsFromUnrestrictedOrMissingSandbox(_ value: String) {
        #expect(!CLISocketSentryPolicy(
            environment: ["CODEX_SANDBOX": value]
        ).allowsSandboxPolicyDenial)
    }

    @Test func doesNotInferSandboxFromAgentIdentity() {
        #expect(!CLISocketSentryPolicy(
            environment: [
                "CODEX_CI": "1",
                "CMUX_AGENT_LAUNCH_KIND": "codex"
            ]
        ).allowsSandboxPolicyDenial)
    }

    @Test func suppressesOwnedSocketEPERMForVerifiedClaudeHook() {
        let policy = CLISocketSentryPolicy(
            environment: [
                "CMUX_CLAUDE_PID": "4242",
                "CMUX_WORKSPACE_ID": "workspace-id",
                "CMUX_SURFACE_ID": "surface-id",
            ],
            command: "hooks",
            subcommand: "claude"
        )

        #expect(policy.shouldSuppressPolicyDenial(.ownedSocketEPERM))
    }

    @Test func suppressesOwnedSocketEPERMForVerifiedCodexSandbox() {
        let policy = CLISocketSentryPolicy(
            environment: ["CODEX_SANDBOX": "workspace-write"],
            command: "ping",
            subcommand: "help"
        )

        #expect(policy.shouldSuppressPolicyDenial(.ownedSocketEPERM))
    }

    @Test func policyDenialTruthTableKeepsUnverifiedAndMismatchedFailures() {
        let unknown = CLISocketSentryPolicy(
            environment: [:],
            command: "hooks",
            subcommand: "claude"
        )
        #expect(!unknown.shouldSuppressPolicyDenial(.ownedSocketEPERM))

        let claudeHook = CLISocketSentryPolicy(
            environment: [
                "CMUX_CLAUDE_PID": "4242",
                "CMUX_WORKSPACE_ID": "workspace-id",
                "CMUX_SURFACE_ID": "surface-id",
            ],
            command: "hooks",
            subcommand: "claude"
        )
        #expect(!claudeHook.shouldSuppressPolicyDenial(.init(
            stage: "socket_connect",
            errnoCode: 1,
            socketExists: true,
            socketIsUnixDomainSocket: true,
            socketOwnerUID: 502,
            processUID: 501,
            effectiveUID: 501
        )))
        #expect(!claudeHook.shouldSuppressPolicyDenial(.init(
            stage: "socket_connect",
            errnoCode: 1,
            socketExists: true,
            socketIsUnixDomainSocket: false,
            socketOwnerUID: 501,
            processUID: 501,
            effectiveUID: 501
        )))
        #expect(!claudeHook.shouldSuppressPolicyDenial(.init(
            stage: "socket_connect",
            errnoCode: 13,
            socketExists: true,
            socketIsUnixDomainSocket: true,
            socketOwnerUID: 501,
            processUID: 501,
            effectiveUID: 501
        )))

        let normalTerminal = CLISocketSentryPolicy(
            environment: [
                "CMUX_CLAUDE_PID": "4242",
                "CMUX_WORKSPACE_ID": "workspace-id",
                "CMUX_SURFACE_ID": "surface-id",
            ],
            command: "ping",
            subcommand: "help"
        )
        #expect(!normalTerminal.shouldSuppressPolicyDenial(.ownedSocketEPERM))
    }

    @Test func socketConnectErrorHasStableNSErrorIdentityAndFingerprint() {
        let first = CLISocketConnectError(path: "/tmp/cmux-a.sock", errnoCode: 1)
        let second = CLISocketConnectError(path: "/tmp/cmux-b.sock", errnoCode: 1)
        let firstNSError = first as NSError
        let secondNSError = second as NSError

        #expect(firstNSError.domain == "com.cmux.cli.socket-connect")
        #expect(firstNSError.domain == secondNSError.domain)
        #expect(firstNSError.code == secondNSError.code)
        #expect(first.sentryFingerprint == second.sentryFingerprint)
        #expect(first.description.contains("/tmp/cmux-a.sock"))
        #expect(first.description.contains("errno 1"))
        #expect(!firstNSError.domain.contains("unknown context"))
        #expect(!firstNSError.domain.contains("$"))
    }

    @Test func socketConnectErrorRejectsMalformedSystemErrorText() {
        let valid = CLISocketConnectError.decodeSystemErrorMessage(
            bytes: Array("Permission denied".utf8),
            errnoCode: 1
        )
        let malformed = CLISocketConnectError.decodeSystemErrorMessage(
            bytes: [0xFF, 0xFE],
            errnoCode: 1
        )

        #expect(valid == "Permission denied")
        #expect(malformed.contains("1"))
        #expect(!malformed.contains("\u{FFFD}"))
    }
}

private extension CLISocketPolicyDenialContext {
    static let ownedSocketEPERM = Self(
        stage: "socket_connect",
        errnoCode: 1,
        socketExists: true,
        socketIsUnixDomainSocket: true,
        socketOwnerUID: 501,
        processUID: 501,
        effectiveUID: 501
    )
}
