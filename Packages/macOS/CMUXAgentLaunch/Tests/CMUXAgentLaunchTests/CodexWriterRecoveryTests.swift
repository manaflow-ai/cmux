import Foundation
import Testing

@testable import CMUXAgentLaunch

@Suite("Codex writer recovery")
struct CodexWriterRecoveryTests {
    @Test("ignores app-server text in a Codex prompt")
    func promptIsNotAnAppServerSubcommand() {
        let holder = CodexWriterProcessEvidence(
            pid: 12345,
            parentPID: 1,
            command: "codex exec app-server --listen ws://127.0.0.1:59152",
            executablePath: "/opt/codex/bin/codex"
        )
        #expect(!holder.isCodexAppServer)
    }

    @Test("rejects remote and shared daemon transports")
    func remoteListenersAreNotRecoverable() {
        for endpoint in ["unix:///tmp/codex.sock", "ws://0.0.0.0:59152", "wss://remote.example:59152"] {
            let holder = CodexWriterProcessEvidence(
                pid: 12345,
                parentPID: 1,
                command: "codex app-server --listen \(endpoint)",
                executablePath: "/opt/codex/bin/codex",
                pidVersion: 1
            )
            #expect(holder.appServerPort == nil)
            #expect(CodexWriterRecoveryAssessment(holder: holder, watchedAppServerPorts: []).classification != .orphanedAppServer)
        }
    }

    @Test("identifies an orphaned app-server holder without treating a live watcher as orphaned")
    func identifiesOrphanedAppServerHolder() {
        let orphan = CodexWriterProcessEvidence(
            pid: 59152,
            parentPID: 1,
            command: "codex app-server --listen ws://127.0.0.1:59152",
            executablePath: "/opt/codex/bin/codex",
            pidVersion: 1,
            isPrivateCmuxServer: true,
            hasConnectedClients: false,
            hasControllingTerminal: false
        )
        let live = CodexWriterProcessEvidence(
            pid: 59111,
            parentPID: 1234,
            command: "codex app-server --listen ws://127.0.0.1:59111",
            executablePath: "/opt/codex/bin/codex"
        )

        #expect(
            CodexWriterRecoveryAssessment(
                holder: orphan,
                watchedAppServerPorts: []
            ).classification == .orphanedAppServer
        )
        #expect(
            CodexWriterRecoveryAssessment(
                holder: live,
                watchedAppServerPorts: [59111]
            ).classification == .ownedAppServer
        )
        #expect(orphan.appServerPort == 59152)
        #expect(orphan.validatedExecutableName == "codex")
        #expect(
            CodexWriterRecoveryAssessment(
                holder: orphan,
                watchedAppServerPorts: [59152]
            ).classification == .ownedAppServer
        )
        let unverified = CodexWriterProcessEvidence(
            pid: 59152,
            parentPID: 1,
            command: "worker codex app-server --listen ws://127.0.0.1:59152",
            executablePath: "/opt/tools/worker"
        )
        #expect(!unverified.isCodexAppServer)
        #expect(
            CodexWriterRecoveryAssessment(
                holder: unverified,
                watchedAppServerPorts: []
            ).classification == .other
        )
    }

    @Test("parses recovery and resume thread IDs without mistaking remote arguments")
    func parsesThreadIDsAndRemoteProvider() {
        let threadID = "01234567-89ab-cdef-0123-456789abcdef"

        #expect(
            CodexWriterRecovery.resumeSessionID(arguments: ["codex", "resume", threadID]) == threadID
        )
        #expect(
            CodexWriterRecovery.resumeSessionID(arguments: ["recover", threadID, "--yes"]) == threadID
        )
        #expect(
            CodexWriterRecovery.codexResumeSessionID(arguments: ["codex", "resume", threadID]) == threadID
        )
        #expect(
            CodexWriterRecovery.codexResumeSessionID(arguments: ["other-agent", "resume", threadID]) == nil
        )
        #expect(
            CodexWriterRecovery.usesRemoteProvider(arguments: ["codex", "resume", threadID, "--remote", "ws://127.0.0.1:1"])
        )
        #expect(
            !CodexWriterRecovery.usesRemoteProvider(arguments: ["codex", "resume", threadID, "--", "--remote"])
        )
    }

    @Test("recognizes only the structured Codex active-writer failure")
    func recognizesWriterConflict() {
        #expect(
            CodexWriterRecovery.isWriterConflict(
                code: -32600,
                message: "Thread 123 already has an\nactive writer"
            )
        )
        #expect(
            !CodexWriterRecovery.isWriterConflict(
                code: -32600,
                message: "Thread 123 was not found"
            )
        )
        #expect(
            !CodexWriterRecovery.isWriterConflict(
                code: nil,
                message: "Thread 123 already has an active writer"
            )
        )
    }

    @Test("recognizes legacy Codex resumes without treating other shell commands as Codex")
    func parsesLegacyResumeCommands() {
        let sessionID = "01234567-89ab-cdef-0123-456789abcdef"
        #expect(
            CodexWriterRecovery.codexLegacyResume(
                inShellCommand: "/bin/sh -lc 'env CMUX_AGENT_RESTORE_LAUNCH=codex:\(sessionID) codex resume \(sessionID)'",
                environment: [:]
            )?.arguments == ["codex", "resume", sessionID]
        )
        #expect(
            CodexWriterRecovery.codexLegacyResume(
                inShellCommand: "cd -- '/tmp/project' && env CODEX_HOME=/tmp/codex /opt/bin/codex resume '\(sessionID)'",
                environment: [:]
            )?.arguments == ["/opt/bin/codex", "resume", sessionID]
        )
        #expect(
            CodexWriterRecovery.codexLegacyResume(
                inShellCommand: "cd -- '/tmp/project' && env CODEX_HOME=/tmp/codex /opt/bin/codex resume '\(sessionID)'",
                environment: [:]
            )?.environment["CODEX_HOME"] == "/tmp/codex"
        )
        let wrapped = AgentResumeArgv.portableCodexResumeShellCommand(
            posixCommand: "\(AgentResumeArgv.codexWrapperShellExecutableToken) resume '\(sessionID)'"
        )
        #expect(
            CodexWriterRecovery.codexLegacyResume(inShellCommand: wrapped, environment: [:])?.arguments
                == ["codex", "resume", sessionID]
        )
        #expect(
            CodexWriterRecovery.codexLegacyResume(
                inShellCommand: "echo 'codex resume \(sessionID)'",
                environment: [:]
            ) == nil
        )
    }

    @Test("fails closed when Codex writer-lock parents are missing")
    func missingWriterLockParentsAreUnavailable() throws {
        let sessionID = "01234567-89ab-cdef-0123-456789abcdef"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-writer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingHome = CodexWriterLockInspector().inspect(
            sessionID: sessionID,
            codexHome: root.path
        )
        #expect(missingHome.state == .unavailable)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let missingLocksDirectory = CodexWriterLockInspector().inspect(
            sessionID: sessionID,
            codexHome: root.path
        )
        #expect(missingLocksDirectory.state == .unavailable)

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("thread-writer-locks", isDirectory: true),
            withIntermediateDirectories: false
        )
        let available = CodexWriterLockInspector().inspect(
            sessionID: sessionID,
            codexHome: root.path
        )
        #expect(available.state == .available)
    }
}
