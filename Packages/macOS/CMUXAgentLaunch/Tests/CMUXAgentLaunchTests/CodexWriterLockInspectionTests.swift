#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite(.serialized)
struct CodexWriterLockInspectionTests {
    @Test("an existing but unlocked lock file is available")
    func unlockedFileIsNotTreatedAsAnActiveWriter() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLockFile(for: fixture.sessionID)

        let inspection = CodexWriterLockInspector().inspect(
            sessionID: fixture.sessionID,
            codexHome: fixture.codexHome.path
        )

        #expect(inspection.state == .available)
        #expect(FileManager.default.fileExists(atPath: inspection.lockPath))
    }

    @Test("a held lock is reported active without changing the file")
    func heldLockIsActiveAndPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let descriptor = try fixture.holdLock(for: fixture.sessionID)
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        let inspection = CodexWriterLockInspector().inspect(
            sessionID: fixture.sessionID,
            codexHome: fixture.codexHome.path
        )

        #expect(inspection.state == .active)
        #expect(FileManager.default.fileExists(atPath: inspection.lockPath))
    }

    @Test("a released lock becomes available on the next probe")
    func releasedLockIsAvailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let descriptor = try fixture.holdLock(for: fixture.sessionID)

        #expect(
            CodexWriterLockInspector().inspect(
                sessionID: fixture.sessionID,
                codexHome: fixture.codexHome.path
            ).state == .active
        )

        #expect(flock(descriptor, LOCK_UN) == 0)
        close(descriptor)

        #expect(
            CodexWriterLockInspector().inspect(
                sessionID: fixture.sessionID,
                codexHome: fixture.codexHome.path
            ).state == .available
        )
    }

    @Test("writer locks are isolated by effective Codex home")
    func homesAreIsolated() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let otherHome = fixture.root.appendingPathComponent("other-codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: otherHome.appendingPathComponent("thread-writer-locks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let descriptor = try fixture.holdLock(for: fixture.sessionID)
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        let inspector = CodexWriterLockInspector()
        #expect(
            inspector.inspect(sessionID: fixture.sessionID, codexHome: fixture.codexHome.path).state
                == .active
        )
        #expect(
            inspector.inspect(sessionID: fixture.sessionID, codexHome: otherHome.path).state
                == .available
        )
    }

    @Test("a missing lock does not create a lock file")
    func missingLockIsAvailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = CodexWriterLockInspector().inspect(sessionID: fixture.sessionID, codexHome: fixture.codexHome.path)
        #expect(result.state == .available)
        #expect(!FileManager.default.fileExists(atPath: result.lockPath))
    }

    @Test("malformed identities and nonregular lock paths fail closed")
    func invalidLockIsUnavailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inspector = CodexWriterLockInspector()
        #expect(inspector.inspect(sessionID: "../escape", codexHome: fixture.codexHome.path).state == .unavailable)
        let path = fixture.codexHome.appendingPathComponent("thread-writer-locks/\(fixture.sessionID).lock")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        #expect(inspector.inspect(sessionID: fixture.sessionID, codexHome: fixture.codexHome.path).state == .unavailable)
    }

    @Test("a lock-file symlink cannot authorize startup")
    func symlinkLockIsUnavailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.codexHome.appendingPathComponent("thread-writer-locks/\(fixture.sessionID).lock")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: fixture.root.appendingPathComponent("missing"))
        #expect(CodexWriterLockInspector().inspect(sessionID: fixture.sessionID, codexHome: fixture.codexHome.path).state == .unavailable)
    }

    @Test("a home symlink uses the same kernel lock")
    func homeAliasIsIsolatedByInode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let descriptor = try fixture.holdLock(for: fixture.sessionID)
        defer { close(descriptor) }
        let alias = fixture.root.appendingPathComponent("account-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.codexHome)
        #expect(CodexWriterLockInspector().inspect(sessionID: fixture.sessionID.uppercased(), codexHome: alias.path).state == .active)
    }

    private static let fixtureSessionID = "01a06e0d-8793-7f33-b044-2b49a10c2260"
    private let fixtureSessionID = Self.fixtureSessionID

    private final class Fixture {
        let root: URL
        let codexHome: URL
        let sessionID = CodexWriterLockInspectionTests.fixtureSessionID

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-codex-writer-\(UUID().uuidString)", isDirectory: true)
            codexHome = root.appendingPathComponent("codex", isDirectory: true)
            try FileManager.default.createDirectory(
                at: codexHome.appendingPathComponent("thread-writer-locks", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        func createLockFile(for sessionID: String) throws {
            let path = codexHome
                .appendingPathComponent("thread-writer-locks", isDirectory: true)
                .appendingPathComponent(sessionID + ".lock", isDirectory: false)
            guard FileManager.default.createFile(atPath: path.path, contents: Data()) else {
                throw FixtureError.file
            }
        }

        func holdLock(for sessionID: String) throws -> Int32 {
            let path = codexHome
                .appendingPathComponent("thread-writer-locks", isDirectory: true)
                .appendingPathComponent(sessionID + ".lock", isDirectory: false)
            let descriptor = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if descriptor >= 0 { close(descriptor) }
                throw FixtureError.lock
            }
            return descriptor
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private enum FixtureError: Error {
            case file
            case lock
        }
    }
}
