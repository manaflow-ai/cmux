@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MobileSSHDisconnectOwnershipTests {
    @Test func canceledAutomaticOpenCannotStartAfterDisconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-auto-disconnect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let computers = MobileSSHComputers(directory: directory)
        let host = SSHHostRecord(name: "box", endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "nobody"))
        try await computers.saveHost(host)
        let opening = try #require(computers.autoConnect(hostID: host.id))
        await computers.disconnect(hostID: host.id)
        await opening.value
        #expect(computers.statusByHost[host.id] == .idle)
        #expect(!computers.canAutoConnect(hostID: host.id))
    }

    @Test func slowTeardownCannotRemoveReplacementProviderOrResetItsStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-disconnect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let computers = MobileSSHComputers(directory: directory)
        let host = SSHHostRecord(name: "box", endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "nobody"))
        try await computers.saveHost(host)
        let old = SSHDisconnectProvider()
        computers.installProviderForTesting(old, hostID: host.id)
        await computers.refreshWorkspaces(hostID: host.id)
        let workspace = try #require(computers.workspacesByHostSnapshot(host.id)?.first)
        let terminal = try #require(workspace.terminals.first)
        let surface = MobileSSHIdentifier(host: host.id, local: terminal.id).rawValue
        var attached = old.attached.makeAsyncIterator()
        var written = old.written.makeAsyncIterator()
        var detaching = old.detaching.makeAsyncIterator()
        computers.viewportChanged(surfaceID: surface, columns: 80, rows: 24)
        computers.replay(surfaceID: surface)
        await attached.next()
        computers.input(Data("queued".utf8), surfaceID: surface)
        old.finishAttach()
        await written.next() // The production attach path has installed the handle.
        await computers.attachTasks[surface]?.value

        var resizing = old.resizing.makeAsyncIterator()
        computers.viewportChanged(surfaceID: surface, columns: 81, rows: 24)
        await resizing.next()
        computers.viewportReleased(surfaceID: surface)
        computers.viewportChanged(surfaceID: surface, columns: 82, rows: 24)
        let queuedSizing = try #require(computers.sizingTasks[surface])

        let disconnect = Task { await computers.disconnect(hostID: host.id) }
        await detaching.next()
        #expect(computers.statusByHost[host.id] == .idle)
        let replacement = SSHDisconnectProvider()
        computers.installProviderForTesting(replacement, hostID: host.id)
        await computers.refreshWorkspaces(hostID: host.id)
        #expect(computers.statusByHost[host.id] == .connected)
        old.finishDetach()
        await disconnect.value
        old.finishResize()
        await queuedSizing.value
        #expect(old.sizes == [81])
        #expect(old.geometryReleases == 0)

        #expect(computers.statusByHost[host.id] == .connected)
        await computers.refreshWorkspaces(hostID: host.id)
        #expect(replacement.listCount == 2)
        await computers.disconnect(hostID: host.id)
    }
}
