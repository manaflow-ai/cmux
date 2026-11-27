@testable import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSSH
import Foundation
import Testing

/// B6: a tmux pane's one-shot seed (capture-pane) or a cmux-tui `vt-state`
/// is sent once per attach. It must reach the terminal view however the
/// attach and the view's subscription interleave, and it must be taken at
/// the phone's real grid, never at a placeholder size.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MobileSSHSeedDeliveryTests {
    /// A tmux stand-in whose attach answers with a one-shot seed at once,
    /// before any live output, and records the grid it was attached at.
    @MainActor
    final class SeedingProvider: MobileSSHWorkspaceProvider {
        let (attaches, attachContinuation) = AsyncStream<(columns: Int, rows: Int)>.makeStream()
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
            attachContinuation.yield((columns, rows))
            events(.snapshot(Data("SEED-PAINT".utf8)))
            return Attached()
        }
    }

    final class Attached: MobileSSHAttachedTerminal {
        func write(_ data: Data) async {}
        func resize(columns: Int, rows: Int) async {}
        func detach() async {}
    }

    private func makeStore() async throws -> (MobileShellComposite, MobileSSHComputers, SeedingProvider, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-seed-\(UUID().uuidString)")
        let computers = MobileSSHComputers(directory: dir)
        let host = SSHHostRecord(name: "box", endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "nobody"))
        try await computers.saveHost(host)
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: MobileShellDemoContentTests.RecordingPairedMacStore(),
            identityProvider: StaticIdentityProvider(userID: "ssh-seed-user"),
            teamIDProvider: { "team-a" },
            sshComputers: computers
        )
        computers.sink = store
        let provider = SeedingProvider()
        computers.installProviderForTesting(provider, hostID: host.id)
        await computers.refreshWorkspaces(hostID: host.id)
        let surface = MobileSSHIdentifier(host: host.id, local: MobileSSHLocalID.tmux("work/%1").rawValue).rawValue
        #expect(store.workspaces.contains { $0.terminals.contains { $0.id.rawValue == surface } })
        return (store, computers, provider, surface)
    }

    /// Reads a surface's stream the way the mounted view does (each chunk
    /// acknowledged before the next is released) until `marker` appears,
    /// and returns everything read.
    private func read(
        _ stream: AsyncStream<MobileTerminalOutputChunk>,
        store: MobileShellComposite,
        surfaceID: String,
        until marker: String
    ) async -> String {
        var text = ""
        for await chunk in stream {
            text += String(decoding: chunk.data, as: UTF8.self)
            store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: chunk.streamToken)
            if text.contains(marker) { break }
        }
        return text
    }

    /// The seed arrives while no view is subscribed (the view is between
    /// mounts). The runtime keeps it, and the next subscription paints it.
    @Test func seedDeliveredBeforeSubscriptionReachesTheFirstSubscriber() async throws {
        let (store, computers, provider, surface) = try await makeStore()
        computers.viewportChanged(surfaceID: surface, columns: 100, rows: 30)
        computers.replay(surfaceID: surface)
        var attaches = provider.attaches.makeAsyncIterator()
        _ = await attaches.next()
        // Output after the seed, still before anyone subscribes.
        provider.events?(.output(Data("LIVE-TAIL".utf8)))
        #expect(!store.hasTerminalOutputSink(surfaceID: surface))

        let preparation = try #require(store.prepareTerminalViewport(surfaceID: surface, columns: 100, rows: 30))
        let stream = store.terminalOutputStream(surfaceID: surface, ownerID: UUID(), releaseViewportOnTermination: false)
        _ = await store.updatePreparedTerminalViewport(preparation)
        let text = await read(stream, store: store, surfaceID: surface, until: "LIVE-TAIL")
        #expect(text.contains("SEED-PAINT"))
        #expect(text.range(of: "SEED-PAINT")!.lowerBound < text.range(of: "LIVE-TAIL")!.lowerBound)
    }

    /// A remount whose predecessor tears down late: the old presentation
    /// releases its viewport after the new view has subscribed, which
    /// retires the new view's viewport negotiation. The SSH attach must not
    /// hang on that negotiation; the new view still gets the seed, taken at
    /// the grid the view reported.
    @Test func lateTeardownOfThePreviousViewDoesNotStrandTheSeed() async throws {
        let (store, _, provider, surface) = try await makeStore()
        let preparation = try #require(store.prepareTerminalViewport(surfaceID: surface, columns: 100, rows: 30))
        let stream = store.terminalOutputStream(surfaceID: surface, ownerID: UUID(), releaseViewportOnTermination: false)
        // The previous presentation's teardown lands now.
        store.clearTerminalViewport(surfaceID: surface)
        _ = await store.updatePreparedTerminalViewport(preparation)

        var attaches = provider.attaches.makeAsyncIterator()
        let grid = try #require(await attaches.next())
        #expect(grid.columns == 100 && grid.rows == 30)
        let text = await read(stream, store: store, surfaceID: surface, until: "SEED-PAINT")
        #expect(text.contains("SEED-PAINT"))
    }

    /// A replay that runs before the phone has reported any grid waits for
    /// it: the seed is taken at the real size, never at 80x24 and then
    /// resized.
    @Test func attachWaitsForThePhonesGrid() async throws {
        let (_, computers, provider, surface) = try await makeStore()
        computers.replay(surfaceID: surface)
        computers.viewportChanged(surfaceID: surface, columns: 120, rows: 40)
        var attaches = provider.attaches.makeAsyncIterator()
        let grid = try #require(await attaches.next())
        #expect(grid.columns == 120 && grid.rows == 40)
    }
}
