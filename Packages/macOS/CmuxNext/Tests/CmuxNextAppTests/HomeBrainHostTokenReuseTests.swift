import Foundation
import Synchronization
import Testing
@testable import CmuxNextApp

/// Every build that opened Home minted a new agent_mux token, and the owner
/// revoked the running brain's binding: the brain lost about 1 s mid-send
/// ("read cursor N: binding lost"; live incident nxdog81, 2026-10-09). A Home
/// that opens while a live host holds the Chief home's lock keeps its token.
@Suite(.timeLimit(.minutes(1))) nonisolated struct HomeBrainHostTokenReuseTests {
    @Test func aHomeThatOpensBesideARunningHostMintsNoToken() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try "running-token".write(to: fixture.host.tokenFile, atomically: true, encoding: .utf8)
        let lock = try #require(ChiefMigration.HostLock(path: fixture.lockFile))
        defer { lock.release() }

        let mints = Mutex(0)
        let outcome = try await fixture.host.start {
            mints.withLock { $0 += 1 }
            return "new-token"
        }

        #expect(outcome == .reusedRunningHost)
        #expect(mints.withLock { $0 } == 0)
        #expect(try String(contentsOf: fixture.host.tokenFile, encoding: .utf8) == "running-token")
    }

    @Test func withoutARunningHostHomeMintsAndLaunches() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let mints = Mutex(0)
        let outcome = try await fixture.host.start {
            mints.withLock { $0 += 1 }
            return "new-token"
        }

        #expect(outcome == .launched)
        #expect(mints.withLock { $0 } == 1)
        #expect(try String(contentsOf: fixture.host.tokenFile, encoding: .utf8) == "new-token")
    }

    /// A held lock without the token file cannot reconnect: mint again.
    @Test func aRunningHostWithoutItsTokenFileGetsANewToken() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lock = try #require(ChiefMigration.HostLock(path: fixture.lockFile))
        defer { lock.release() }

        let mints = Mutex(0)
        let outcome = try await fixture.host.start {
            mints.withLock { $0 += 1 }
            return "new-token"
        }

        #expect(outcome == .launched)
        #expect(mints.withLock { $0 } == 1)
    }

    struct Fixture {
        let root: URL
        let host: HomeBrainHost
        var lockFile: URL { host.muxHome.appendingPathComponent("state/host.lock") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("brain-token-\(UUID().uuidString)", isDirectory: true)
            let muxHome = root.appendingPathComponent("chief", isDirectory: true)
            try FileManager.default.createDirectory(at: muxHome.appendingPathComponent("state"), withIntermediateDirectories: true)
            // A stand-in host that exits at once.
            let script = root.appendingPathComponent("fake-host.sh")
            try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            host = HomeBrainHost(executable: script, muxHome: muxHome, daemonSocket: root.appendingPathComponent("d.sock").path,
                                 controlSocket: root.appendingPathComponent("c.sock").path, acpmux: nil)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
