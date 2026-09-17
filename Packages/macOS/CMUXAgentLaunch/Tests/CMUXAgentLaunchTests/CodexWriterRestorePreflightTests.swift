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
        let replaced = CodexWriterOwner(pid: owner.pid, startSeconds: owner.startSeconds + 1, startMicroseconds: owner.startMicroseconds, executable: owner.executable, workingDirectory: owner.workingDirectory, ttyDevice: owner.ttyDevice, ancestorPIDs: owner.ancestorPIDs)
        #expect(!inspector.isCurrent(replaced, inspection: lock))
    }

    @Test("the captured verification home selects the account when the child names no CODEX_HOME")
    func verificationHomeSelectsTheAccount() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // The lock lives under <verification home>/.codex, not under the child's HOME.
        let verificationHome = fixture.root.appendingPathComponent("saved-user")
        try FileManager.default.createDirectory(
            at: verificationHome.appendingPathComponent(".codex/thread-writer-locks"),
            withIntermediateDirectories: true
        )
        let lockPath = verificationHome.appendingPathComponent(".codex/thread-writer-locks/\(sessionID).lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let service = CodexWriterRestorePreflight { _ in CodexWriterOwnerScan(owners: [], isComplete: false) }

        let bound = service.inspect(
            sessionID: sessionID, arguments: ["codex", "resume", sessionID],
            environment: ["HOME": "/other-user"], workingDirectory: fixture.root.path,
            verificationHome: verificationHome.path, fallbackHome: "/another"
        )
        #expect(!bound.permitsLaunch)
        #expect(bound.lock?.lockPath == Self.kernelPath(lockPath))

        // An explicit CODEX_HOME in the child environment still wins over the capture.
        let explicit = service.inspect(
            sessionID: sessionID, arguments: ["codex", "resume", sessionID],
            environment: ["CODEX_HOME": fixture.home.path, "HOME": "/other-user"], workingDirectory: fixture.root.path,
            verificationHome: verificationHome.path, fallbackHome: "/another"
        )
        #expect(explicit.permitsLaunch)
        #expect(explicit.lock?.codexHome == Self.kernelPath(fixture.home.path))
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

    /// The inspector reports realpath-resolved paths (`/var` -> `/private/var`).
    private static func kernelPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
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
