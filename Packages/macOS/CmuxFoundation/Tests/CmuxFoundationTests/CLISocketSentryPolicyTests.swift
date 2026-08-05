import Darwin
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
        #expect(first.description == second.description)
        #expect(!first.description.contains("/tmp/cmux-a.sock"))
        #expect(!first.description.localizedCaseInsensitiveContains("errno"))
        #expect(!first.description.localizedCaseInsensitiveContains("permission denied"))
        #expect(first.telemetryContext["socket_path"] == "/tmp/cmux-a.sock")
        #expect(first.telemetryContext["errno"] == "1")
        #expect(!(first.telemetryContext["system_error"] ?? "").isEmpty)
        #expect(!firstNSError.domain.contains("unknown context"))
        #expect(!firstNSError.domain.contains("$"))
    }

    @Test func typedSocketDiagnosticsOverrideGenericOperationContext() {
        let error = CLISocketConnectError(path: "/tmp/cmux-authoritative.sock", errnoCode: EACCES)
        let context = CLISocketErrorTelemetryContext().merging(
            base: [
                "cwd": "/tmp/base",
                "socket_path": "/tmp/base.sock",
            ],
            operation: [
                "operation": "connect",
                "socket_path": "/tmp/stale.sock",
                "errno": "999",
                "system_error": "stale",
            ],
            error: error
        )

        #expect(context["cwd"] as? String == "/tmp/base")
        #expect(context["operation"] as? String == "connect")
        #expect(context["socket_path"] as? String == "/tmp/cmux-authoritative.sock")
        #expect(context["errno"] as? String == String(EACCES))
        #expect(context["system_error"] as? String != "stale")
    }

    @Test func policyInspectionFollowsSymlinkToUnixSocket() throws {
        let suffix = UUID().uuidString.lowercased()
        let targetPath = "/tmp/cmux-policy-target-\(suffix).sock"
        let symlinkPath = "/tmp/cmux-policy-link-\(suffix).sock"
        let listener = try bindUnixSocket(at: targetPath)
        defer {
            Darwin.close(listener)
            Darwin.unlink(symlinkPath)
            Darwin.unlink(targetPath)
        }
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath,
            withDestinationPath: targetPath
        )

        let context = CLISocketPolicyDenialContext(
            inspectingStage: "socket_connect",
            error: CLISocketConnectError(path: symlinkPath, errnoCode: EPERM)
        )

        #expect(context.socketExists)
        #expect(context.socketIsUnixDomainSocket)
        #expect(context.socketOwnerUID == getuid())
        #expect(context.processUID == getuid())
        #expect(context.effectiveUID == geteuid())
    }

    @Test func socketConnectErrorRejectsMalformedSystemErrorText() {
        let valid = decodeSystemErrorMessage(
            bytes: Array("Permission denied".utf8),
            errnoCode: 1
        )
        let malformed = decodeSystemErrorMessage(
            bytes: [0xFF, 0xFE],
            errnoCode: 1
        )

        #expect(valid == "Permission denied")
        #expect(!malformed.isEmpty)
        #expect(malformed != valid)
        #expect(!malformed.contains("\u{FFFD}"))
    }
}

private func bindUnixSocket(at path: String) throws -> Int32 {
    Darwin.unlink(path)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maximumLength = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maximumLength else {
        Darwin.close(descriptor)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
    }
    path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            let buffer = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
            strncpy(buffer, source, maximumLength - 1)
        }
    }

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
            Darwin.bind(
                descriptor,
                socketPointer,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
    guard bindResult == 0 else {
        let code = errno
        Darwin.close(descriptor)
        Darwin.unlink(path)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
    return descriptor
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
