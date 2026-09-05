import Darwin
import Foundation
import Testing
@testable import CMUXAgentLaunch

struct CodexWriterRestorePreflightTests {
    private let sessionID = "01a06e0d-8793-7f33-b044-2b49a10c2260"

    @Test("a writer released during discovery does not block or focus a stale owner")
    func releaseDuringDiscovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fd = try fixture.hold(sessionID)
        defer { close(fd) }
        let service = CodexWriterRestorePreflight { _ in
            _ = flock(fd, LOCK_UN)
            return CodexWriterOwnerScan(owners: [], isComplete: true)
        }
        let result = service.inspect(
            sessionID: sessionID, arguments: ["codex", "resume", sessionID],
            environment: ["CODEX_HOME": fixture.home.path], workingDirectory: fixture.root.path,
            fallbackHome: fixture.root.path
        )
        #expect(result.permitsLaunch)
        #expect(result.owners.isEmpty)
        #expect(result.mappedSurface(in: []) == nil)
    }

    @Test("the final child cwd resolves a relative account instead of PWD or fallback HOME")
    func relativeHome() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fd = try fixture.hold(sessionID)
        defer { close(fd) }
        let service = CodexWriterRestorePreflight { _ in CodexWriterOwnerScan(owners: [], isComplete: false) }
        let result = service.inspect(
            sessionID: sessionID, arguments: ["codex", "resume", sessionID],
            environment: ["CODEX_HOME": "account", "HOME": "/unrelated", "PWD": "/stale"],
            workingDirectory: fixture.root.path, fallbackHome: "/another"
        )
        #expect(!result.permitsLaunch)
        #expect(result.lock?.state == .active)
    }

    @Test("remote flags are recognized only as options", arguments: [
        (["codex", "--remote", "ws://host", "resume", "thread"], true),
        (["codex", "resume", "thread", "--remote=ws://host"], true),
        (["codex", "-c", "--remote=not-an-option", "resume", "thread"], false),
        (["codex", "--model", "--remote", "resume", "thread"], false),
        (["codex", "resume", "thread", "--", "--remote=prompt"], false),
        (["codex", "resume", "thread", "ask about --remote=endpoint"], false),
    ])
    func remoteScope(arguments: [String], expected: Bool) {
        #expect(CodexWriterRestorePreflight().usesRemoteProvider(arguments: arguments) == expected)
    }

    @Test("ambiguous or incomplete ownership never maps to a surface")
    func conservativeMapping() {
        let lock = CodexWriterLockInspection(state: .active, codexHome: "/account", lockPath: "/account/lock", device: 1, inode: 2)
        let owner = CodexWriterOwner(pid: 300, startSeconds: 10, startMicroseconds: 2, executable: "/codex", workingDirectory: "/project", ttyDevice: 123, ancestorPIDs: [300, 200, 100])
        let target = CodexWriterSurfaceIdentity(containerID: UUID(), surfaceID: UUID(), generation: 4, foregroundPID: 200, ttyDevice: 123)
        let stale = CodexWriterSurfaceIdentity(containerID: target.containerID, surfaceID: target.surfaceID, generation: 3, foregroundPID: 999, ttyDevice: 123)
        let wrongTTY = CodexWriterSurfaceIdentity(containerID: target.containerID, surfaceID: target.surfaceID, generation: 4, foregroundPID: 200, ttyDevice: 456)
        let result = CodexWriterRestoreInspection(lock: lock, owners: [owner])
        #expect(result.mappedSurface(in: [target]) == target)
        #expect(result.mappedSurface(in: [stale]) == nil)
        #expect(result.mappedSurface(in: [wrongTTY]) == nil)
        #expect(result.mappedSurface(in: [target, target]) == nil)
        #expect(CodexWriterRestoreInspection(lock: lock, owners: []).mappedSurface(in: [target]) == nil)
        #expect(CodexWriterRestoreInspection(lock: lock, owners: [owner, owner]).mappedSurface(in: [target]) == nil)
        #expect(CodexWriterRestoreInspection(lock: lock, owners: [owner], ownerScanComplete: false).mappedSurface(in: [target]) == nil)
        let released = CodexWriterLockInspection(state: .available, codexHome: "/account", lockPath: "/account/lock", device: 1, inode: 2)
        #expect(CodexWriterRestoreInspection(lock: released, owners: [owner]).mappedSurface(in: [target]) == nil)
    }

    @Test("live holder generation is checked before continuation")
    func processGeneration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fd = try fixture.hold(sessionID)
        defer { close(fd) }
        let lock = CodexWriterLockInspector().inspect(sessionID: sessionID, codexHome: fixture.home.path)
        let inspector = CodexWriterProcessInspector()
        let scan = inspector.owners(for: lock)
        let owner = try #require(scan.owners.first(where: { $0.pid == getpid() }))
        #expect(inspector.isCurrent(owner, inspection: lock))
        #expect(inspector.descendsFromForeground(owner, foregroundPID: Int(getpid())))
        let replaced = CodexWriterOwner(pid: owner.pid, startSeconds: owner.startSeconds + 1, startMicroseconds: owner.startMicroseconds, executable: owner.executable, workingDirectory: owner.workingDirectory, ttyDevice: owner.ttyDevice, ancestorPIDs: owner.ancestorPIDs)
        #expect(!inspector.isCurrent(replaced, inspection: lock))
        #expect(!inspector.descendsFromForeground(replaced, foregroundPID: Int(getpid())))
    }

    @Test("verification home stays bound to the child account")
    func verificationHomeIsReplayed() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent, kind: "codex", checkpointID: sessionID, source: "test",
            workingDirectory: "/project", environment: [:],
            launchCommand: AgentLaunchCommand(arguments: ["codex"], verificationHome: "/saved-user"),
            preparedArguments: nil, observedPermissionMode: nil
        )
        let result = try #require(AgentRestorePlanner(isExecutableFile: { _ in false }).invocation(
            for: request, ambientEnvironment: ["CODEX_HOME": "/ambient-account", "HOME": "/other-user"]
        ))
        #expect(result.environment["CODEX_HOME"] == "/saved-user/.codex")
        #expect(result.codexResumeSessionID == sessionID)
    }

    @Test("legacy literal commands preserve account and reject shell expansion")
    func legacyScope() {
        let prefix = "env CODEX_HOME='/accounts/codex user' /opt/codex resume "
        let literal = CodexLegacyRestoreCommand(command: prefix + sessionID, sessionID: sessionID)
        #expect(literal?.environment["CODEX_HOME"] == "/accounts/codex user")
        #expect(literal?.arguments == ["/opt/codex", "resume", sessionID])
        for command in [
            "codex resume " + sessionID,
            "CODEX_HOME=relative codex resume " + sessionID,
            "CODEX_HOME=$OTHER codex resume " + sessionID,
            prefix + UUID().uuidString,
            prefix + sessionID + "; touch /tmp/never",
            "cd /different && " + prefix + sessionID,
            "env CODEX_HOME=$(pwd) codex resume " + sessionID,
        ] {
            #expect(CodexLegacyRestoreCommand(command: command, sessionID: sessionID) == nil)
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-writer-policy-" + UUID().uuidString)
            home = root.appendingPathComponent("account")
            try FileManager.default.createDirectory(at: home.appendingPathComponent("thread-writer-locks"), withIntermediateDirectories: true)
        }

        func hold(_ sessionID: String) throws -> Int32 {
            let path = home.appendingPathComponent("thread-writer-locks/\(sessionID).lock").path
            let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            try #require(fd >= 0)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw CocoaError(.fileWriteUnknown) }
            return fd
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
