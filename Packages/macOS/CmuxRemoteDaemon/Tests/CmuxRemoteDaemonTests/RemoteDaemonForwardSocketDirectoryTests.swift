import Darwin
import Foundation
import Testing
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemonForwardSocketDirectory")
struct RemoteDaemonForwardSocketDirectoryTests {
    /// A short scratch directory owned by this user with mode 0700.
    private func makeScratchParent() throws -> String {
        var template = Array("/private/tmp/cmuxfwdtest.XXXXXX".utf8CString)
        let created = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) != nil }
        try #require(created)
        return template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private func fileMode(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode
    }

    @Test("creates a fresh 0700 directory whose socket path ssh binds verbatim")
    func createsPrivateDirectory() throws {
        let parent = try makeScratchParent()
        defer { rmdir(parent) }

        let directory = try RemoteDaemonForwardSocketDirectory.create(parents: [parent + "/"])
        defer { directory.remove() }

        #expect(directory.path.hasPrefix(parent + "/cmuxd."))
        #expect(directory.socketPath == directory.path + "/d.sock")
        #expect(RemoteDaemonForwardSocketDirectory.isBindablePath(directory.socketPath))
        let mode = try #require(fileMode(directory.path))
        #expect(mode & S_IFMT == S_IFDIR)
        #expect(mode & 0o777 == 0o700)
    }

    @Test("skips parents that are too long, need ssh path expansion or are shared-writable")
    func skipsUnusableParents() throws {
        let fallback = try makeScratchParent()
        defer { rmdir(fallback) }
        let shared = try makeScratchParent()
        defer { rmdir(shared) }
        #expect(chmod(shared, 0o777) == 0)

        let directory = try RemoteDaemonForwardSocketDirectory.create(parents: [
            "/private/tmp/" + String(repeating: "p", count: 100),
            "/private/tmp/%d",
            shared,
            fallback,
        ])
        defer { directory.remove() }

        #expect(directory.path.hasPrefix(fallback + "/cmuxd."))
    }

    @Test("fails without creating anything when no parent is usable")
    func failsWithoutUsableParent() throws {
        let shared = try makeScratchParent()
        defer { rmdir(shared) }
        #expect(chmod(shared, 0o777) == 0)

        #expect(throws: (any Error).self) {
            try RemoteDaemonForwardSocketDirectory.create(parents: [shared])
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: shared)) == [])
    }

    @Test("remove deletes the socket and directory but never other contents")
    func removeIsNotRecursive() throws {
        let parent = try makeScratchParent()
        defer { rmdir(parent) }

        let emptied = try RemoteDaemonForwardSocketDirectory.create(parents: [parent])
        #expect(FileManager.default.createFile(atPath: emptied.socketPath, contents: Data()))
        emptied.remove()
        #expect(fileMode(emptied.path) == nil)

        let occupied = try RemoteDaemonForwardSocketDirectory.create(parents: [parent])
        let stray = occupied.path + "/stray"
        #expect(FileManager.default.createFile(atPath: stray, contents: Data()))
        occupied.remove()
        #expect(fileMode(stray) != nil)
        unlink(stray)
        occupied.remove()
        #expect(fileMode(occupied.path) == nil)
    }
}
