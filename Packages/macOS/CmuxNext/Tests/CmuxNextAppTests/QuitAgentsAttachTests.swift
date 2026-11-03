import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextApp

/// A DEV build attached to another app's acpmux (`CMUX_NEXT_ACPMUX_ATTACH`) never counts or
/// ends that daemon's agents at quit: they are its owner's.
@MainActor
@Suite(.serialized)
struct QuitAgentsAttachTests {
    nonisolated final class Connections: Sendable {
        let count = Mutex(0)
    }

    /// A home whose socket accepts and counts connections but never answers: an owned quit
    /// connects to end its agents and fails when it does not answer; an attached quit never connects.
    private static func silentDaemon() throws -> (root: URL, environment: AcpmuxEnvironment, descriptor: Int32,
                                                   connections: Connections) {
        let root = URL(fileURLWithPath: "/tmp/qaa-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let acpmux = bin.appendingPathComponent("acpmux")
        try "#!/bin/sh\nexit 1\n".write(to: acpmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
        let environment = try #require(AcpmuxEnvironment.resolve(
            build: nil, bundledBinDirectory: bin, environment: ["ACPMUX_HOME": home.path],
            executableOverride: nil, teamIdentifier: nil))
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = environment.socketPath
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        let connections = Connections()
        Thread.detachNewThread {
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                connections.count.withLock { $0 += 1 }
                Thread.detachNewThread { var byte: UInt8 = 0; while recv(client, &byte, 1, 0) > 0 {}; close(client) }
            }
        }
        return (root, environment, descriptor, connections)
    }

    @Test func anAttachedQuitNeitherCountsNorEndsAgents() async throws {
        let (root, own, descriptor, connections) = try Self.silentDaemon()
        defer { shutdown(descriptor, SHUT_RDWR); close(descriptor); try? FileManager.default.removeItem(at: root) }
        let attached = own.attached(to: own.home)

        #expect(await QuitAgents.facts(attached) == .zero)
        #expect(await QuitAgents.end(attached).isEmpty)
        #expect(connections.count.withLock { $0 } == 0, "an attached quit reached the other app's daemon")
        #expect(QuitAgents.isAttached(attached, to: URL(fileURLWithPath: own.home.path + "/", isDirectory: true)))
        #expect(!QuitAgents.isAttached(own, to: own.home))
        // The same daemon, owned: the quit asks it and reports that it did not answer.
        let owned = await QuitAgents.end(own)
        #expect(!owned.isEmpty)
        #expect(connections.count.withLock { $0 } > 0)
    }
}
