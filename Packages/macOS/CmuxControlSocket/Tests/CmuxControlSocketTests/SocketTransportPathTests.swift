import Darwin
import Foundation
import Testing

@testable import CmuxControlSocket

@Suite struct SocketTransportPathIdentityTests {
    let transport = SocketTransport()

    @Test func pathIdentityOnlyAcceptsUnixSocketFiles() throws {
        let directory = URL(
            fileURLWithPath: "/tmp/cmux-ctlsock-id-\(UUID().uuidString.lowercased().prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plainFile = directory.appendingPathComponent("plain-file")
        #expect(FileManager.default.createFile(atPath: plainFile.path, contents: Data()))
        #expect(transport.pathIdentity(at: plainFile.path) == nil)

        let socketPath = directory.appendingPathComponent("s").path
        let socketFD = try UnixSocketFixture.bindListeningSocket(at: socketPath)
        defer {
            Darwin.close(socketFD)
            Darwin.unlink(socketPath)
        }

        let identity = try #require(transport.pathIdentity(at: socketPath))
        #expect(transport.pathExists(socketPath, matching: identity))
        #expect(
            !transport.pathExists(
                socketPath,
                matching: SocketPathIdentity(device: identity.device, inode: identity.inode + 1)
            )
        )
        #expect(!transport.pathExists(socketPath, matching: nil))
    }

    @Test func pathIdentityReportsMissingPath() {
        #expect(transport.pathIdentity(at: UnixSocketFixture.makeTempSocketPath()) == nil)
    }
}

@Suite struct SocketTransportProbeTests {
    let transport = SocketTransport()

    @Test func pathAcceptsConnectionsForLiveUnixSocket() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        let handled = UnixSocketFixture.acceptSingleClient(on: listenerFD) { _ in }

        #expect(transport.pathAcceptsConnections(path))
        #expect(handled.wait(timeout: .now() + 1.0) == .success)
    }

    @Test func pathAcceptsConnectionsRejectsStaleSocketFile() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        Darwin.close(listenerFD)
        defer { unlink(path) }

        #expect(!transport.pathAcceptsConnections(path))
        #expect(transport.pathProbeResult(at: path) == .refused)
    }

    @Test func probeResultIsStaleForMissingPath() {
        #expect(transport.pathProbeResult(at: UnixSocketFixture.makeTempSocketPath()) == .stale)
    }
}

@Suite struct SocketTransportBindPreparationTests {
    let transport = SocketTransport()

    @Test func prepareSocketPathForBindRejectsRegularFileWithoutDeletingIt() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        try "not-a-socket".write(toFile: path, atomically: true, encoding: .utf8)
        defer { unlink(path) }

        let failure = try #require(transport.prepareSocketPathForBind(path))

        #expect(failure.stage == "existing_path")
        #expect(failure.errnoCode == EEXIST)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func prepareSocketPathForBindRejectsLiveSocketWithoutDeletingIt() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        let handled = UnixSocketFixture.acceptSingleClient(on: listenerFD) { _ in }
        let failure = try #require(transport.prepareSocketPathForBind(path))

        #expect(failure.stage == "bind")
        #expect(failure.errnoCode == EADDRINUSE)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(handled.wait(timeout: .now() + 1.0) == .success)
    }

    @Test func prepareSocketPathForBindPreservesRefusedSocketFileWithoutPathLock() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        Darwin.close(listenerFD)
        defer { unlink(path) }

        let failure = try #require(transport.prepareSocketPathForBind(path))

        #expect(failure.stage == "bind")
        #expect(failure.errnoCode == EADDRINUSE)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func prepareSocketPathForBindRemovesRefusedSocketFileWithReusablePathLock() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        Darwin.close(listenerFD)
        defer { unlink(path) }

        #expect(transport.prepareSocketPathForBind(path, canReplaceRefusedSocket: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func bindListenerSocketBindsAndCapturesIdentity() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer {
            Darwin.close(fd)
            unlink(path)
        }

        let result = transport.bindListenerSocket(fd, path: path, canReplaceRefusedSocket: false)
        guard case .success(let boundPath, let identity) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(boundPath == path)
        #expect(transport.pathExists(path, matching: identity))
    }

    @Test func bindListenerSocketReportsPathTooLong() {
        let path = "/tmp/" + String(repeating: "x", count: SocketTransport.unixSocketPathMaxLength + 8) + ".sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { Darwin.close(fd) }

        #expect(
            transport.bindListenerSocket(fd, path: path, canReplaceRefusedSocket: false)
                == .pathTooLong(path: path)
        )
    }
}

@Suite struct SocketTransportLockTests {
    let transport = SocketTransport()

    @Test func startupReclaimabilityAllowsMissingSocketWithoutLock() {
        let path = UnixSocketFixture.makeTempSocketPath()
        defer {
            unlink(path)
            unlink(path + ".lock")
        }

        #expect(transport.pathCanBeReclaimedForStartup(path))
    }

    @Test func startupReclaimabilityRejectsMissingSocketWithInvalidLock() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let lockPath = path + ".lock"
        let targetPath = path + ".target"
        try "preserve me".write(toFile: targetPath, atomically: true, encoding: .utf8)
        #expect(symlink(targetPath, lockPath) == 0)
        defer {
            unlink(path)
            unlink(lockPath)
            unlink(targetPath)
        }

        #expect(!transport.pathCanBeReclaimedForStartup(path))
        #expect(try String(contentsOfFile: targetPath, encoding: .utf8) == "preserve me")
    }

    @Test func acquireLockRejectsSymlinkedLockWithoutTouchingTarget() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let lockPath = path + ".lock"
        let targetPath = path + ".target"
        try "preserve me".write(toFile: targetPath, atomically: true, encoding: .utf8)
        #expect(symlink(targetPath, lockPath) == 0)
        defer {
            unlink(path)
            unlink(lockPath)
            unlink(targetPath)
        }

        guard case .failed(let failure) = transport.acquireSocketPathLock(for: path) else {
            Issue.record("expected lock acquisition to fail on a symlinked lock path")
            return
        }
        #expect(failure.stage == "open_lock")
        #expect(try String(contentsOfFile: targetPath, encoding: .utf8) == "preserve me")
    }

    @Test func acquiredLockBecomesReusableAfterMarking() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        defer {
            unlink(path)
            unlink(path + ".lock")
        }

        guard case .acquired(let fd, let canReplace) = transport.acquireSocketPathLock(for: path) else {
            Issue.record("expected lock acquisition to succeed")
            return
        }
        // A fresh anonymous temp path carries no reusable marker and no
        // well-known cmux filename, so a refused socket may not be replaced.
        #expect(!canReplace)

        transport.markSocketPathLockReusable(fd)
        transport.releaseSocketPathLock(fd)

        guard case .acquired(let fd2, let canReplace2) = transport.acquireSocketPathLock(for: path) else {
            Issue.record("expected lock re-acquisition to succeed")
            return
        }
        #expect(canReplace2)
        transport.releaseSocketPathLock(fd2)
    }

    @Test func taggedDebugSocketFilenamesMayReplaceUnmarkedRefusedSockets() throws {
        let path = "/tmp/cmux-debug-reclaim-\(UUID().uuidString.lowercased()).sock"
        defer {
            unlink(path)
            unlink(path + ".lock")
        }

        guard case .acquired(let fd, let canReplace) = transport.acquireSocketPathLock(for: path) else {
            Issue.record("expected lock acquisition to succeed")
            return
        }
        #expect(canReplace)
        transport.releaseSocketPathLock(fd)
    }

    @Test func secondAcquisitionFailsWhileLockIsHeld() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        defer {
            unlink(path)
            unlink(path + ".lock")
        }

        guard case .acquired(let fd, _) = transport.acquireSocketPathLock(for: path) else {
            Issue.record("expected lock acquisition to succeed")
            return
        }
        defer { transport.releaseSocketPathLock(fd) }

        guard case .failed(let failure) = transport.acquireSocketPathLock(for: path) else {
            Issue.record("expected concurrent lock acquisition to fail")
            return
        }
        #expect(failure.stage == "lock")
        #expect(failure.errnoCode == EWOULDBLOCK)
    }
}
