import Darwin
import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct CodexWriterLockTests {
    @Test func simultaneousReadOnlyProbesDoNotReportEachOtherAsWriters() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = try fixture.hold()
        defer { close(writer) }
        #expect(flock(writer, LOCK_UN) == 0)
        // A second cmux probe is compatible with this read-only observation.
        #expect(flock(writer, LOCK_SH | LOCK_NB) == 0)
        #expect(fixture.inspect().state == .available)
        let coordination = open(fixture.locks.appendingPathComponent(".coordination.lock").path,
                                O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(coordination >= 0)
        defer { close(coordination) }
        #expect(flock(coordination, LOCK_SH | LOCK_NB) == 0)
        #expect(fixture.inspect().state == .available)
    }

    private struct Fixture {
        let session = UUID().uuidString.lowercased()
        let home: URL
        let locks: URL
        var path: String { locks.appendingPathComponent(session + ".lock").path }

        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            locks = home.appendingPathComponent("thread-writer-locks")
            try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: home) }
        func inspect() -> CodexWriterLockInspection {
            CodexWriterLockInspector().inspect(sessionID: session, codexHome: home.path)
        }

        func hold(_ path: String? = nil) throws -> Int32 {
            let fd = open(path ?? self.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            #expect(fd >= 0)
            #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
            return try #require(fd >= 0 ? fd : nil)
        }
    }

    @Test func checksKernelOwnershipAndNeverRemovesOrRetainsTheLock() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fd = try fixture.hold()
        defer { close(fd) }
        #expect(fixture.inspect().state == .active)
        #expect(FileManager.default.fileExists(atPath: fixture.path))
        #expect(flock(fd, LOCK_UN) == 0)
        #expect(fixture.inspect().state == .available)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        #expect(fixture.inspect().state == .active)
    }

    @Test func absentLocksDoNotCreateProviderFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(fixture.inspect().state == .available)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.locks.path).isEmpty)
        try FileManager.default.removeItem(at: fixture.locks)
        #expect(fixture.inspect().state == .available)
        #expect(!FileManager.default.fileExists(atPath: fixture.locks.path))
    }

    @Test func coordinationContentionIsRetryableWithoutInventingAWriter() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let coordination = try fixture.hold(fixture.locks.appendingPathComponent(".coordination.lock").path)
        defer { close(coordination) }
        let writer = try fixture.hold()
        defer { close(writer) }
        #expect(fixture.inspect().state == .changing)
        #expect(flock(coordination, LOCK_UN) == 0)
        #expect(fixture.inspect().state == .active)
        #expect(flock(writer, LOCK_UN) == 0)
        #expect(fixture.inspect().state == .available)
        #expect(flock(coordination, LOCK_EX | LOCK_NB) == 0)
    }

    @Test func malformedAndNonregularPathsFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(CodexWriterLockInspector().inspect(sessionID: "../escape", codexHome: fixture.home.path).state == .unavailable)
        #expect(CodexWriterLockInspector().inspect(sessionID: fixture.session, codexHome: "relative").state == .unavailable)
        #expect(CodexWriterLockInspector().inspect(sessionID: fixture.session, codexHome: fixture.home.path + "\0").state == .unavailable)
        #expect(mkfifo(fixture.path, S_IRUSR | S_IWUSR) == 0)
        #expect(fixture.inspect().state == .unavailable)
        #expect(unlink(fixture.path) == 0)
        let target = fixture.home.appendingPathComponent("target").path
        #expect(FileManager.default.createFile(atPath: target, contents: Data()))
        #expect(symlink(target, fixture.path) == 0)
        #expect(fixture.inspect().state == .unavailable)
    }

}
