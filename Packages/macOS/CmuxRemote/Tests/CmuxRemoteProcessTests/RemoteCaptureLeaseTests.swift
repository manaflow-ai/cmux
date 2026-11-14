import CmuxDeviceHub
import CmuxRemoteWire
@testable import CmuxRemoteHost
import Darwin
import Foundation
import Testing
import os

@Suite struct RemoteCaptureLeaseTests {
    struct Fixture {
        let root: String
        var state: String { root + "/remote" }
        let scope = "com.cmuxterm.remote.capture.s0123"
        var binding: CaptureLeaseBinding {
            get throws { try #require(CaptureLeaseBinding(fields: ["lease_id": "0123456789abcdef01234567",
                "bundle_id": "com.cmuxterm.app.debug.capturetest", "private_root": root])) }
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("remote-capture-" + UUID().uuidString).path
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }

        func remove() { try? FileManager.default.removeItem(atPath: root) }
        func producer(empty: @escaping @Sendable () throws -> Bool = { true },
                      remove: @escaping @Sendable () throws -> DeviceCaptureNamespace.Removal = { .init(identities: 0, relays: 0) }) -> RemoteCaptureLease {
            RemoteCaptureLease(stateDirectory: state, keychainScope: scope, home: root, empty: empty, remove: remove)
        }
    }

    @Test func prepareNeverDeletesPreexistingItems() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let lease = fixture.producer(empty: { false }, remove: {
            calls.withLock { $0 += 1 }; return .init(identities: 3, relays: 1)
        })
        let children = RemoteChildLifetime()
        let result = await lease.prepare(try fixture.binding, children: children, workerAbsent: true)
        #expect(!result.leaseBound)
        #expect(children.accepting)
        #expect(calls.withLock { $0 } == 0)
        #expect(try CaptureLeaseMarker.read(stateDirectory: fixture.state) == nil)
    }

    @Test func unreadableNamespaceCannotBePrepared() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let lease = fixture.producer(empty: { throw CocoaError(.fileReadNoPermission) })
        let children = RemoteChildLifetime()
        let result = await lease.prepare(try fixture.binding, children: children, workerAbsent: true)
        #expect(!result.verifiedAbsent && !result.leaseBound)
        #expect(children.accepting)
        #expect(try CaptureLeaseMarker.read(stateDirectory: fixture.state) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func preparedHostCannotSpawnButFreshHostCanResumeActiveLease() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let children = RemoteChildLifetime()
        let prepared = await fixture.producer().prepare(try fixture.binding, children: children, workerAbsent: true)
        #expect(prepared.leaseBound && prepared.quiescent)
        #expect(!children.accepting)
        children.reopenAfterPrepare()
        #expect(!children.accepting)
        #expect(throws: (any Error).self) {
            try children.spawn(executable: "/bin/cat", arguments: [], environment: [:], logPath: "/dev/null")
        }
        #expect(await children.waitUntilEmpty(timeout: .seconds(1)))
        let marker = try #require(CaptureLeaseMarker.read(stateDirectory: fixture.state))
        #expect(!marker.cleaning && !marker.workerStarted)

        // A process restart creates a new admission boundary, while retaining the active lease.
        let freshChildren = RemoteChildLifetime()
        let child = try freshChildren.spawn(executable: "/bin/cat", arguments: [], environment: [:], logPath: "/dev/null")
        defer { close(child.stdout) }
        ChildProcess.watch(child.pid, name: "capture-prepared-host-restart") { status in
            if status >= 0 { freshChildren.reaped(child) }
        }
        close(child.stdin)
        #expect(await freshChildren.waitUntilEmpty(timeout: .seconds(5)))
        try CaptureLeaseMarker.authorizeIdentity(stateDirectory: fixture.state, keychainScope: fixture.scope, home: fixture.root)
        let resumed = try #require(CaptureLeaseMarker.read(stateDirectory: fixture.state))
        #expect(resumed.workerStarted && !resumed.cleaning)
    }

    @Test func wrongPrepareLeaseDoesNotFreezeAdmissionOrChangeMarker() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let lease = fixture.producer()
        _ = await lease.prepare(try fixture.binding, children: RemoteChildLifetime(), workerAbsent: true)
        let original = try CaptureLeaseMarker.read(stateDirectory: fixture.state)
        let wrong = try #require(CaptureLeaseBinding(fields: ["lease_id": "aaaaaaaaaaaaaaaaaaaaaaaa",
            "bundle_id": "com.cmuxterm.app.debug.capturetest", "private_root": fixture.root]))
        let children = RemoteChildLifetime()
        let rejected = await lease.prepare(wrong, children: children, workerAbsent: true)
        #expect(!rejected.leaseBound && children.accepting)
        #expect(try CaptureLeaseMarker.read(stateDirectory: fixture.state) == original)
    }

    @Test func wrongLeaseCannotBeginDrainOrDelete() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let lease = fixture.producer(remove: { calls.withLock { $0 += 1 }; return .init(identities: 0, relays: 0) })
        _ = await lease.prepare(try fixture.binding, children: RemoteChildLifetime(), workerAbsent: true)
        let wrong = try #require(CaptureLeaseBinding(fields: ["lease_id": "aaaaaaaaaaaaaaaaaaaaaaaa",
            "bundle_id": "com.cmuxterm.app.debug.capturetest", "private_root": fixture.root]))
        #expect(await lease.beginCleanup(wrong) == false)
        let result = await lease.cleanup(wrong, writersExited: true)
        #expect(result.code == "remote_lease_mismatch")
        #expect(calls.withLock { $0 } == 0)
        #expect(try CaptureLeaseMarker.read(stateDirectory: fixture.state)?.cleaning == false)
    }

    @Test func writerTimeoutRetainsDurableRestartFenceWithoutDeleting() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let lease = fixture.producer(remove: { calls.withLock { $0 += 1 }; return .init(identities: 3, relays: 0) })
        let binding = try fixture.binding
        _ = await lease.prepare(binding, children: RemoteChildLifetime(), workerAbsent: true)
        try CaptureLeaseMarker.authorizeIdentity(stateDirectory: fixture.state, keychainScope: fixture.scope, home: fixture.root)
        #expect(await lease.beginCleanup(binding))
        let result = await lease.cleanup(binding, writersExited: false)
        #expect(result.code == "remote_worker_timeout")
        #expect(calls.withLock { $0 } == 0)
        #expect(try CaptureLeaseMarker.read(stateDirectory: fixture.state)?.cleaning == true)
        #expect(throws: (any Error).self) {
            try CaptureLeaseMarker.authorizeIdentity(stateDirectory: fixture.state, keychainScope: fixture.scope, home: fixture.root)
        }
        // A new producer after a host crash cannot reuse the lease for another writer.
        let afterRestart = await fixture.producer().prepare(binding, children: RemoteChildLifetime(), workerAbsent: true)
        #expect(!afterRestart.leaseBound)
    }

    @Test func cleanupRequiresDrainAndDoesNotAttestItsOwnHostExit() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let lease = fixture.producer(remove: { .init(identities: 3, relays: 2) })
        let binding = try fixture.binding
        let prepared = await lease.prepare(binding, children: RemoteChildLifetime(), workerAbsent: true)
        #expect(prepared.code == "no_remote_started" && prepared.identities == 0 && prepared.relays == 0)
        let beforeDrain = await lease.cleanup(binding, writersExited: true)
        #expect(beforeDrain.code == "remote_lease_mismatch")
        try CaptureLeaseMarker.authorizeIdentity(stateDirectory: fixture.state, keychainScope: fixture.scope, home: fixture.root)
        #expect(await lease.beginCleanup(binding))
        let cleaned = await lease.cleanup(binding, writersExited: true)
        #expect(cleaned.code == "remote_exit_unverified" && cleaned.workerStarted)
        #expect(cleaned.identities == 3 && cleaned.relays == 2 && cleaned.verifiedAbsent && cleaned.quiescent)
        #expect(cleaned.fields["ok"] as? Bool == false)
        #expect(cleaned.fields["worker_pid_exited"] as? Bool == false)
        #expect(cleaned.fields["descendants_exited"] as? Bool == false)
        #expect(try CaptureLeaseMarker.read(stateDirectory: fixture.state)?.cleaning == true)
    }

    @Test func deletionFailureRetainsMarkerAndFailsClosed() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let lease = fixture.producer(remove: { throw CocoaError(.fileWriteNoPermission) })
        let binding = try fixture.binding
        _ = await lease.prepare(binding, children: RemoteChildLifetime(), workerAbsent: true)
        #expect(await lease.beginCleanup(binding))
        let result = await lease.cleanup(binding, writersExited: true)
        #expect(!result.verifiedAbsent && result.code == "remote_cleanup_unverified")
        #expect(try CaptureLeaseMarker.read(stateDirectory: fixture.state)?.cleaning == true)
    }

    @Test func markerRejectsSymlinkAndConcurrentMutation() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try CaptureLeaseMarker.transaction(stateDirectory: fixture.state) { marker in
            marker = CaptureLeaseMarker(binding: try fixture.binding, keychainScope: fixture.scope)
            #expect(throws: (any Error).self) {
                try CaptureLeaseMarker.transaction(stateDirectory: fixture.state) { _ in }
            }
        }
        let linkState = fixture.root + "/linkstate"
        try FileManager.default.createDirectory(atPath: linkState, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: CaptureLeaseMarker.path(stateDirectory: linkState),
                                                  withDestinationPath: CaptureLeaseMarker.path(stateDirectory: fixture.state))
        #expect(throws: (any Error).self) { try CaptureLeaseMarker.read(stateDirectory: linkState) }
    }

    @Test func workerPreservesThePreparedPrivateHome() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let environment = RemoteHost.workerEnvironment(hubURL: nil, headless: true, home: fixture.root)
        #expect(environment["HOME"] == fixture.root)
        #expect(environment["CLOUD_CAPTURE_REFRESH_TOKEN"] == nil)
    }

    @Test func validatesExactRequestAndPrivateHome() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let binding = try fixture.binding
        #expect(binding.owns(stateDirectory: fixture.state, home: fixture.root))
        #expect(!binding.owns(stateDirectory: fixture.state, home: NSHomeDirectory()))
        #expect(!binding.owns(stateDirectory: fixture.root + "-other/state", home: fixture.root))
        var fields: [String: Any] = ["lease_id": binding.leaseID, "bundle_id": binding.bundleID, "private_root": fixture.root]
        for (key, value) in [("lease_id", "ABCDEF012345678901234567"), ("bundle_id", "com.cmuxterm.app"),
                             ("bundle_id", "com.cmuxterm.app.debug."), ("private_root", fixture.root + "/../x"),
                             ("private_root", fixture.root + "\0tail")] {
            var invalid = fields; invalid[key] = value
            #expect(CaptureLeaseBinding(fields: invalid) == nil)
        }
        fields["host_id"] = "unexpected"
        #expect(CaptureLeaseBinding(fields: fields) == nil)
        #expect(chmod(fixture.root, 0o755) == 0)
        #expect(!binding.owns(stateDirectory: fixture.state, home: fixture.root))
    }
}
