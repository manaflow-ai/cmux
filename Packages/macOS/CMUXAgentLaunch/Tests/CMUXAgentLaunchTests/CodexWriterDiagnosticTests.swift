import Darwin
import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct CodexWriterDiagnosticTests {
    @Test func candidatesAreDiagnosticOnlyAndDisappearWhenTheLockIsReleased() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let locks = root.appendingPathComponent("thread-writer-locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID().uuidString.lowercased()
        let fd = open(locks.appendingPathComponent(session + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let held = CodexWriterLockInspector().inspect(sessionID: session, codexHome: root.path)
        #expect(held.state == .active)
        let inspector = CodexWriterProcessInspector(processIDs: { [getpid()] }, uptime: { 0 })
        let candidates = inspector.candidates(for: held)
        #expect(candidates.map(\.processID) == [getpid()])
        let message = CodexWriterRestoreNotice().message(candidates: candidates)
        #expect(message.contains(String(getpid())))
        #expect(!message.contains(session))
        #expect(!message.contains(root.path))
        #expect(CodexWriterProcessInspector(processIDs: { [getpid()] }, uptime: { 0 }, maximumDuration: 0)
            .candidates(for: held).isEmpty)
        #expect(CodexWriterLockInspector().inspect(sessionID: session, codexHome: root.path).state == .active)
        try #require(flock(fd, LOCK_UN) == 0)
        #expect(inspector.candidates(for: held).isEmpty)
    }
}
