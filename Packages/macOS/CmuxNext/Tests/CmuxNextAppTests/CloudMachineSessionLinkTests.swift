import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Observation
import Synchronization
import Testing
@testable import CmuxNextApp

/// A Cloud machine session on the app link, end to end in the app: a click
/// connects through the link resolver with origin `user`, and the machine's
/// `DaemonService` connects to the socket the link names (a scripted daemon
/// here). After the handshake the app refuses a socket that is this Mac's
/// own daemon (the same boot or the same registry): a wrong link answer must
/// never mirror the local daemon as a Cloud machine.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CloudMachineSessionLinkTests {
    /// Answers `open` with `socket` and records each origin.
    nonisolated final class FakeResolver: CloudLinkResolver {
        let socket: String
        let origins = Mutex<[CloudLinkOrigin]>([])

        init(socket: String) {
            self.socket = socket
        }

        func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
            origins.withLock { $0.append(origin) }
            return CloudLinkSocket(key: key, path: socket, generation: 1)
        }

        func close(_ key: CloudLinkKey) async {}
    }

    nonisolated static func identity(generation: String, registry: String) throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","version":"0.1.0","protocol":12,"capabilities":[],"session":"s","pid":7,"registry_id":"\#(registry)","generation":"\#(generation)","workspace_revision":0}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// The scripted remote daemon: boot `g1`, registry `r`.
    nonisolated static func daemon() -> @Sendable ([String: JSONValue]) -> [String] {
        RemoteMachineCompatTests.daemon { RemoteMachineCompatTests.required }
    }

    private func wait(_ timeout: Duration = .seconds(10), until done: @escaping @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !done() {
            guard clock.now < deadline else { throw DaemonError.timedOut("cloud session state") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aClickConnectsTheMachineDaemonOnTheLinkSocketAsUser() async throws {
        let server = try ScriptedDaemonSocket(handler: Self.daemon())
        defer { server.stop() }
        let resolver = FakeResolver(socket: server.path)
        let machine = CloudMachine(id: "vm-a", status: .paused)
        let local = try Self.identity(generation: "g0", registry: "local")
        let session = CloudMachineSession(machine: machine, appLink: CloudLinkSession(key: CloudLinkKey(machine: machine.id), resolver: resolver),
                                          localIdentity: { local })
        defer { session.disconnect() }
        session.connect(origin: .user)
        try await wait {
            if case .connected = session.daemon.store.connectionState { return true }
            return false
        }
        #expect(resolver.origins.withLock { $0 } == [.user], "a click on a paused machine connects as user")
        #expect(session.linkEnded == nil)
        #expect(session.daemon.identity?.registryID == "r")
    }

    @Test(arguments: [("g1", "other"), ("g9", "r")])
    func theLocalDaemonBehindTheLinkSocketIsRefused(generation: String, registry: String) async throws {
        let server = try ScriptedDaemonSocket(handler: Self.daemon())
        defer { server.stop() }
        let resolver = FakeResolver(socket: server.path)
        let machine = CloudMachine(id: "vm-b")
        let local = try Self.identity(generation: generation, registry: registry)
        let session = CloudMachineSession(machine: machine, appLink: CloudLinkSession(key: CloudLinkKey(machine: machine.id), resolver: resolver),
                                          localIdentity: { local })
        defer { session.disconnect() }
        session.connect(origin: .script)
        try await wait { session.linkEnded != nil }
        #expect(session.linkEnded == CloudStrings.linkFailed(CloudAppLinks.localDaemonDetail))
        #expect(session.daemon.connection == nil, "no mirror of the local daemon")
    }

    @Test func theSameDaemonRuleUsesTheBootOrTheRegistry() throws {
        let remote = try Self.identity(generation: "g1", registry: "r")
        #expect(throws: CloudLinkError.unsafeSocket(CloudAppLinks.localDaemonDetail)) {
            try CloudAppLinks.checkNotLocal(remote: remote, local: try Self.identity(generation: "g1", registry: "x"))
        }
        #expect(throws: CloudLinkError.unsafeSocket(CloudAppLinks.localDaemonDetail)) {
            try CloudAppLinks.checkNotLocal(remote: remote, local: try Self.identity(generation: "g2", registry: "r"))
        }
        try CloudAppLinks.checkNotLocal(remote: remote, local: try Self.identity(generation: "g2", registry: "x"))
        // No local daemon connected: nothing to compare (and no op could run).
        try CloudAppLinks.checkNotLocal(remote: remote, local: nil)
    }
}
