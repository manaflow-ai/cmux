@testable import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSSH
import Foundation
import Testing

/// Reconnect in an SSH workspace's title menu follows the SSH connection:
/// offered when the host is not connected or the shown session ended,
/// never for a live terminal on a connected host.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MobileSSHReconnectTests {
    /// A tmux stand-in whose attachments the test can end.
    @MainActor
    final class EndingProvider: MobileSSHWorkspaceProvider {
        let (attaches, attachContinuation) = AsyncStream<Void>.makeStream()
        var events: (@MainActor (MobileSSHAttachEvent) -> Void)?

        func listWorkspaces() async throws -> [MobileSSHWorkspace] {
            [MobileSSHWorkspace(id: "work", name: "work", terminals: [MobileSSHTerminal(id: "work/%1", name: "0:zsh")])]
        }

        func createWorkspace() async throws -> MobileSSHWorkspace { throw CancellationError() }
        func closeWorkspace(id: String) async throws {}

        func attach(
            terminalID: String,
            columns: Int,
            rows: Int,
            events: @escaping @MainActor (MobileSSHAttachEvent) -> Void
        ) async throws -> any MobileSSHAttachedTerminal {
            self.events = events
            attachContinuation.yield()
            return MobileSSHSeedDeliveryTests.Attached()
        }
    }

    @Test func reconnectFollowsTheHostAndTheShownSession() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-reconnect-\(UUID().uuidString)")
        let computers = MobileSSHComputers(directory: dir)
        computers.sink = RecordingSSHSink()
        let host = SSHHostRecord(name: "box", endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "nobody"))
        try await computers.saveHost(host)
        let surface = MobileSSHIdentifier(host: host.id, local: MobileSSHLocalID.tmux("work/%1").rawValue).rawValue

        // Not connected yet: Reconnect is the way back.
        #expect(computers.canReconnect(hostID: host.id, surfaceID: surface))

        let provider = EndingProvider()
        computers.installProviderForTesting(provider, hostID: host.id)
        await computers.refreshWorkspaces(hostID: host.id)
        computers.viewportChanged(surfaceID: surface, columns: 80, rows: 24)
        computers.replay(surfaceID: surface)
        var attaches = provider.attaches.makeAsyncIterator()
        _ = await attaches.next()

        // Connected with a live session: nothing to reconnect.
        #expect(computers.statusByHost[host.id] == .connected)
        #expect(!computers.canReconnect(hostID: host.id, surfaceID: surface))
        #expect(!computers.canReconnect(hostID: host.id, surfaceID: nil))

        // The session ended on the server: offered, and it reattaches.
        provider.events?(.ended)
        #expect(computers.canReconnect(hostID: host.id, surfaceID: surface))
        await computers.reconnect(hostID: host.id, surfaceID: surface)
        _ = await attaches.next()
        #expect(!computers.canReconnect(hostID: host.id, surfaceID: surface))

        // A failed host offers it again.
        computers.failForTesting(hostID: host.id, MobileSSHRuntimeError.tmuxMissing)
        #expect(computers.canReconnect(hostID: host.id, surfaceID: surface))
    }
}
