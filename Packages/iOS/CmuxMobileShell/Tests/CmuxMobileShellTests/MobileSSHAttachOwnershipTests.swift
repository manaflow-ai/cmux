@testable import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSSH
import Foundation
import Testing

/// An attach that returns after its surface was detached must not publish into
/// a replacement attach for that same surface.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MobileSSHAttachOwnershipTests {
    @MainActor
    final class DelayedProvider: MobileSSHWorkspaceProvider {
        typealias EventHandler = @MainActor (MobileSSHAttachEvent) -> Void

        let (attaches, attachContinuation) = AsyncStream<Int>.makeStream()
        private(set) var attachCount = 0
        private var pending: [Int: CheckedContinuation<any MobileSSHAttachedTerminal, Error>] = [:]
        private var handlers: [Int: EventHandler] = [:]
        private(set) var detached: [Int] = []

        func listWorkspaces() async throws -> [MobileSSHWorkspace] {
            [MobileSSHWorkspace(
                id: "work",
                name: "work",
                terminals: [MobileSSHTerminal(id: "work/%1", name: "0:zsh")]
            )]
        }

        func createWorkspace() async throws -> MobileSSHWorkspace { throw CancellationError() }
        func closeWorkspace(id: String) async throws {}

        func attach(
            terminalID: String,
            columns: Int,
            rows: Int,
            events: @escaping EventHandler
        ) async throws -> any MobileSSHAttachedTerminal {
            attachCount += 1
            let id = attachCount
            handlers[id] = events
            attachContinuation.yield(id)
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
            }
        }

        func resolve(_ id: Int) {
            pending.removeValue(forKey: id)?.resume(returning: Attachment(id: id, owner: self))
        }

        func emit(_ id: Int, _ event: MobileSSHAttachEvent) {
            handlers[id]?(event)
        }

        @MainActor
        final class Attachment: MobileSSHAttachedTerminal {
            let id: Int
            weak var owner: DelayedProvider?

            init(id: Int, owner: DelayedProvider) {
                self.id = id
                self.owner = owner
            }

            func write(_ data: Data) async {}
            func resize(columns: Int, rows: Int) async {}
            func detach() async { owner?.detached.append(id) }
        }
    }

    @Test func lateCanceledAttachCannotPublishIntoReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-attach-ownership-\(UUID().uuidString)")
        let computers = MobileSSHComputers(directory: directory)
        let sink = RecordingSSHSink()
        computers.sink = sink
        let host = SSHHostRecord(
            name: "box",
            endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "nobody")
        )
        try await computers.saveHost(host)

        let provider = DelayedProvider()
        computers.installProviderForTesting(tmux: provider, plain: nil, hostID: host.id)
        await computers.refreshWorkspaces(hostID: host.id)
        let workspace = try #require(computers.workspacesByHostSnapshot(host.id)?.first)
        let terminal = try #require(workspace.terminals.first)
        let surface = MobileSSHIdentifier(host: host.id, local: terminal.id).rawValue

        computers.viewportChanged(surfaceID: surface, columns: 80, rows: 24)
        computers.replay(surfaceID: surface)
        var attaches = provider.attaches.makeAsyncIterator()
        let first = try #require(await attaches.next())

        // closeWorkspace uses the real detach path while leaving this test
        // provider's workspace available for the replacement attach.
        await computers.closeWorkspace(
            scopedID: MobileSSHIdentifier(host: host.id, local: workspace.id).rawValue
        )
        computers.replay(surfaceID: surface)
        let second = try #require(await attaches.next())
        #expect(first == 1)
        #expect(second == 2)

        provider.resolve(first)
        await Task.yield()
        provider.emit(first, .output(Data("STALE-A".utf8)))

        provider.resolve(second)
        await Task.yield()
        provider.emit(second, .output(Data("LIVE-B".utf8)))
        await Task.yield()

        #expect(provider.detached == [1])
        #expect(!(sink.outputs[surface] ?? "").contains("STALE-A"))
        #expect((sink.outputs[surface] ?? "").contains("LIVE-B"))
    }
}
