import Darwin
import Foundation
import Testing
@testable import CmuxComputerUse

/// Answers every request line with `{"ok":true}`, like a healthy cmux-cua daemon
/// answers the health check's `list`.
private final class FakeDaemonListener: @unchecked Sendable {
    private let descriptor: Int32
    private let path: String

    init(socketURL: URL) throws {
        path = socketURL.path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { raw in
                for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        let listening = descriptor
        Thread.detachNewThread {
            while true {
                let client = accept(listening, nil, nil)
                guard client >= 0 else {
                    close(listening)
                    return
                }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                var byte: UInt8 = 0
                while read(client, &byte, 1) == 1, byte != 0x0A {}
                let reply = Array("{\"ok\":true}\n".utf8)
                _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                close(client)
            }
        }
    }

    /// Wakes the accept loop, which closes the socket itself, so the descriptor
    /// number is never reused while the loop can still read it.
    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        unlink(path)
    }
}

/// #25450: macOS clears files older than three days from the temp folder, which
/// removes `auth-token` and leaves the daemon sockets, so agent sessions started
/// after that get no Computer Use.
@MainActor
struct ComputerUseAuthTokenFileRestoreTests {
    private struct Runtime {
        let fixture: HelperRuntimeFixture
        let socketRoot: URL
        let paths: ComputerUseRuntimePaths
        let service: ComputerUseRuntimeService

        @MainActor
        init() throws {
            fixture = try HelperRuntimeFixture()
            // The fixture's own folder is too long for a Unix socket path.
            socketRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("cua-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: true)
            paths = ComputerUseRuntimePaths(
                homeDirectoryURL: fixture.files.root,
                socketRootDirectoryURL: socketRoot,
                environment: [:],
                bundleIdentifier: "helper-tests",
                authenticationToken: "fixture-token",
                hostAuthenticationToken: "fixture-host-token"
            )
            service = ComputerUseRuntimeService(
                bundle: fixture.bundle, paths: paths, helperTrust: HelperRuntimeFixture.trustingEveryHelper
            )
        }

        @MainActor
        func remove() {
            service.stopForTermination()
            try? FileManager.default.removeItem(at: socketRoot)
            fixture.files.remove()
        }

        func startDaemons() throws -> [FakeDaemonListener] {
            [
                try FakeDaemonListener(socketURL: paths.daemonSocketURL),
                try FakeDaemonListener(socketURL: paths.codexDaemonSocketURL),
            ]
        }
    }

    private func tokenFileContents(_ paths: ComputerUseRuntimePaths) -> String? {
        try? String(contentsOf: paths.authenticationTokenFileURL, encoding: .utf8)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    private func inode(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? UInt64)
    }

    @Test func healthCheckWritesTheTokenFileAgainWhileTheHelperRuns() async throws {
        let runtime = try Runtime()
        defer { runtime.remove() }
        #expect(runtime.service.prepareRuntimeForLaunch())
        let daemons = try runtime.startDaemons()
        defer { daemons.forEach { $0.stop() } }
        // What the daily temp-folder cleanup does: the file goes, the sockets stay.
        try FileManager.default.removeItem(at: runtime.paths.authenticationTokenFileURL)

        await runtime.service.checkHelperHealth()

        #expect(tokenFileContents(runtime.paths) == "fixture-token\n")
        #expect(try permissions(at: runtime.paths.authenticationTokenFileURL) == 0o600)
    }

    @Test func healthCheckLeavesAnExistingTokenFileAlone() async throws {
        let runtime = try Runtime()
        defer { runtime.remove() }
        #expect(runtime.service.prepareRuntimeForLaunch())
        let daemons = try runtime.startDaemons()
        defer { daemons.forEach { $0.stop() } }
        let original = try inode(at: runtime.paths.authenticationTokenFileURL)
        let modified = try FileManager.default
            .attributesOfItem(atPath: runtime.paths.authenticationTokenFileURL.path)[.modificationDate] as? Date

        await runtime.service.checkHelperHealth()

        #expect(try inode(at: runtime.paths.authenticationTokenFileURL) == original)
        let after = try FileManager.default
            .attributesOfItem(atPath: runtime.paths.authenticationTokenFileURL.path)[.modificationDate] as? Date
        #expect(after == modified)
    }

    @Test func healthCheckDoesNotWriteATokenFileForAHelperThatIsNotRunning() async throws {
        let runtime = try Runtime()
        defer { runtime.remove() }
        #expect(runtime.service.prepareRuntimeForLaunch())
        try FileManager.default.removeItem(at: runtime.paths.authenticationTokenFileURL)

        await runtime.service.checkHelperHealth()

        #expect(!FileManager.default.fileExists(atPath: runtime.paths.authenticationTokenFileURL.path))
    }

    @Test func healthCheckMakesTheRuntimeFolderPrivateBeforeWritingTheToken() async throws {
        let runtime = try Runtime()
        defer { runtime.remove() }
        #expect(runtime.service.prepareRuntimeForLaunch())
        let daemons = try runtime.startDaemons()
        defer { daemons.forEach { $0.stop() } }
        try FileManager.default.removeItem(at: runtime.paths.authenticationTokenFileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtime.paths.runtimeDirectoryURL.path
        )

        await runtime.service.checkHelperHealth()

        #expect(try permissions(at: runtime.paths.runtimeDirectoryURL) == 0o700)
        #expect(tokenFileContents(runtime.paths) == "fixture-token\n")
    }

    @Test func healthCheckDoesNotWriteTheTokenFileAfterTermination() async throws {
        let runtime = try Runtime()
        defer { runtime.remove() }
        #expect(runtime.service.prepareRuntimeForLaunch())
        try FileManager.default.removeItem(at: runtime.paths.authenticationTokenFileURL)
        runtime.service.stopForTermination()
        // Termination removes the socket files, so listen again afterwards: a
        // daemon that still answers must not bring the file back.
        let daemons = try runtime.startDaemons()
        defer { daemons.forEach { $0.stop() } }

        await runtime.service.checkHelperHealth()

        #expect(!FileManager.default.fileExists(atPath: runtime.paths.authenticationTokenFileURL.path))
    }

    /// A folder under `/tmp` holding only what the test puts there.
    private func emptyFolder() throws -> URL {
        let folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cua-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func writingIfAbsentCreatesAPrivateTokenFileAndNothingElse() throws {
        let folder = try emptyFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tokenURL = folder.appendingPathComponent("auth-token")

        #expect(ComputerUseRuntimeService.writeAuthenticationTokenIfAbsent("fixture-token", to: tokenURL))

        #expect(try String(contentsOf: tokenURL, encoding: .utf8) == "fixture-token\n")
        #expect(try permissions(at: tokenURL) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["auth-token"])
    }

    /// The health check looks first and writes second. A symlink that shows up
    /// between the two must stay where it is, and its target must not get the token.
    @Test func writingIfAbsentLeavesASymlinkThatAppearedAtThePath() throws {
        let folder = try emptyFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tokenURL = folder.appendingPathComponent("auth-token")
        let targetURL = folder.appendingPathComponent("elsewhere")
        try FileManager.default.createSymbolicLink(at: tokenURL, withDestinationURL: targetURL)

        #expect(!ComputerUseRuntimeService.writeAuthenticationTokenIfAbsent("fixture-token", to: tokenURL))

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: tokenURL.path) == targetURL.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["auth-token"])
    }

    @Test func writingIfAbsentLeavesAFileThatAppearedAtThePath() throws {
        let folder = try emptyFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tokenURL = folder.appendingPathComponent("auth-token")
        try "someone-else\n".write(to: tokenURL, atomically: false, encoding: .utf8)

        #expect(!ComputerUseRuntimeService.writeAuthenticationTokenIfAbsent("fixture-token", to: tokenURL))

        #expect(try String(contentsOf: tokenURL, encoding: .utf8) == "someone-else\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["auth-token"])
    }
}
