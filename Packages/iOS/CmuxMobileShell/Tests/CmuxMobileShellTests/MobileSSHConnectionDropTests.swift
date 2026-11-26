@testable import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSSH
import Foundation
import Testing

/// A plain shell that ends when its channel closes and a whole connection that
/// drops under it both have to reach the terminal the user is watching: the
/// "Session ended" line, and a reconnect that repaints without leaving a blank
/// screen. The connection-drop path used to remove the attachment silently and
/// lean on each child channel's own close event, which can lag under load.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MobileSSHConnectionDropTests {
    /// A shell stand-in that answers each attach with a distinct prompt and
    /// can be told its channel ended.
    @MainActor
    final class PromptingProvider: MobileSSHWorkspaceProvider {
        var events: (@MainActor (MobileSSHAttachEvent) -> Void)?
        private(set) var attachCount = 0
        let (attaches, attachContinuation) = AsyncStream<Int>.makeStream()

        func listWorkspaces() async throws -> [MobileSSHWorkspace] {
            [MobileSSHWorkspace(id: "1", name: "Shell 1", terminals: [MobileSSHTerminal(id: "1", name: "Shell 1")], kind: .shell)]
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
            attachCount += 1
            let n = attachCount
            attachContinuation.yield(n)
            events(.output(Data("PROMPT-\(n)$ ".utf8)))
            return MobileSSHSeedDeliveryTests.Attached()
        }
    }

    private func makeSubscribedShell() async throws
        -> (MobileShellComposite, MobileSSHComputers, PromptingProvider, String, AsyncStream<MobileTerminalOutputChunk>)
    {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-drop-\(UUID().uuidString)")
        let computers = MobileSSHComputers(directory: dir)
        let host = SSHHostRecord(name: "box", endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "nobody"))
        try await computers.saveHost(host)
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: MobileShellDemoContentTests.RecordingPairedMacStore(),
            identityProvider: StaticIdentityProvider(userID: "ssh-drop-user"),
            teamIDProvider: { "team-a" },
            sshComputers: computers
        )
        computers.sink = store
        let provider = PromptingProvider()
        computers.installProvidersForTesting(tmux: provider, plain: provider, hostID: host.id)
        await computers.refreshWorkspaces(hostID: host.id)
        let surface = MobileSSHIdentifier(host: host.id, local: MobileSSHLocalID.shell("1").rawValue).rawValue

        // The view mounts and subscribes; the first attach paints PROMPT-1.
        let preparation = try #require(store.prepareTerminalViewport(surfaceID: surface, columns: 80, rows: 24))
        let stream = store.terminalOutputStream(surfaceID: surface, ownerID: UUID(), releaseViewportOnTermination: false)
        _ = await store.updatePreparedTerminalViewport(preparation)
        var attaches = provider.attaches.makeAsyncIterator()
        _ = await attaches.next()
        _ = await read(stream, store: store, surfaceID: surface, until: "PROMPT-1")
        return (store, computers, provider, surface, stream)
    }

    /// Reads a surface's stream the way the mounted view does (each chunk
    /// acknowledged before the next is released) until `marker` appears.
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

    /// The shell's own channel closing prints the "Session ended" line.
    @Test func channelCloseEndsTheShownTerminal() async throws {
        let (store, computers, provider, surface, stream) = try await makeSubscribedShell()
        provider.events?(.ended)
        let text = await read(stream, store: store, surfaceID: surface, until: "Session ended")
        #expect(text.contains("Session ended"))
        #expect(computers.endedSurfaces.contains(surface))
    }

    /// A dropped transport (server death) prints the "Session ended" line in
    /// the shown terminal on its own, without waiting for the child channel's
    /// close event. Regression: the connection-close path used to drop the
    /// attachment silently, so a lagging channel close left no line at all.
    @Test func droppedTransportEndsTheShownTerminal() async throws {
        let (store, computers, _, surface, stream) = try await makeSubscribedShell()
        computers.endHostConnectionForTesting(hostID: try #require(computers.hosts.first).id)
        let text = await read(stream, store: store, surfaceID: surface, until: "Session ended")
        #expect(text.contains("Session ended"))
        #expect(computers.endedSurfaces.contains(surface))
    }

    /// After the session ends, Reconnect on the already-subscribed view
    /// repaints: the new shell's prompt reaches the same stream, never a blank
    /// screen.
    @Test func reconnectWhileSubscribedRepaints() async throws {
        let (store, computers, provider, surface, stream) = try await makeSubscribedShell()
        let hostID = try #require(computers.hosts.first).id
        provider.events?(.ended)
        _ = await read(stream, store: store, surfaceID: surface, until: "Session ended")

        await computers.reconnect(hostID: hostID, surfaceID: surface)
        let text = await read(stream, store: store, surfaceID: surface, until: "PROMPT-2")
        #expect(text.contains("PROMPT-2"))
        #expect(provider.attachCount == 2)
        #expect(!computers.endedSurfaces.contains(surface))
    }
}
