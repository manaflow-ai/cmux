import CmuxMobileCloud
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileCloudBridge

/// New Workspace and New Terminal on a Cloud machine's workspace: made on
/// that machine's daemon, and already in the rows when the call returns, so
/// the phone can open what it just made.
@MainActor
struct CloudCreateTests {
    private final class TerminalLink: CloudTerminalLinking, @unchecked Sendable {
        func send(_ bytes: Data) {}
        func resize(cols: Int, rows: Int) {}
        func detach() {}
    }

    /// A daemon whose catalog grows as the phone creates things.
    private final class MachineLink: CloudMachineLinking, @unchecked Sendable {
        private let lock = NSLock()
        private var workspaces = [CloudWorkspaceSummary(id: "ws-1", name: "api")]
        private var terminals = [
            CloudTerminalSummary(id: "t-1", workspaceID: "ws-1"),
            CloudTerminalSummary(id: "t-pool", workspaceID: nil),
        ]
        private var nextID = 2
        var refuses = false
        /// When set, `createWorkspace` waits for one gate element first, so a
        /// test can hold a create open.
        var createGate: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)?
        private var _createWaiters = 0
        var createWaiters: Int { lock.withLock { _createWaiters } }
        var createdWorkspaceCount: Int { lock.withLock { workspaces.count - 1 } }

        func loadCatalog() async throws -> (
            workspaces: [CloudWorkspaceSummary],
            terminals: [CloudTerminalSummary]
        ) {
            lock.withLock { (workspaces, terminals) }
        }

        func attach(
            terminalID: String,
            output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void
        ) async throws -> any CloudTerminalLinking {
            TerminalLink()
        }

        func createWorkspace(name: String?) async -> String? {
            if let gate = createGate {
                lock.withLock { _createWaiters += 1 }
                var iterator = gate.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            return lock.withLock {
                guard !refuses else { return nil }
                let workspaceID = "ws-\(nextID)"
                terminals.append(CloudTerminalSummary(id: "t-\(nextID)", workspaceID: workspaceID))
                workspaces.append(CloudWorkspaceSummary(id: workspaceID, name: name))
                nextID += 1
                return workspaceID
            }
        }

        func createTerminal(inWorkspace workspaceID: String, name: String?) async -> String? {
            lock.withLock {
                guard !refuses, workspaces.contains(where: { $0.id == workspaceID }) else { return nil }
                let terminalID = "t-\(nextID)"
                terminals.append(CloudTerminalSummary(id: terminalID, workspaceID: workspaceID))
                nextID += 1
                return terminalID
            }
        }
    }

    private final class Provider: CloudMachineLinkProviding {
        let link = MachineLink()
        func link(for machine: CloudMachine) -> (any CloudMachineLinking)? { link }
        func resetLink(for machine: CloudMachine) {}
    }

    private static let machine = CloudMachine(id: "vm-1", provider: "freestyle", status: "running", slug: "sleepy-teal-otter")
    private static let hostID = CloudAddress(machineID: "vm-1").identifier

    /// Lets main-actor work run until `condition` holds, bounded by wall
    /// time rather than a yield count, so a busy runner cannot turn a slow
    /// pass into a failure.
    private func settle(until condition: () -> Bool, timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    private func makeBridge() async -> (CloudWorkspaceBridge, Provider, MobileShellComposite) {
        let provider = Provider()
        let bridge = CloudWorkspaceBridge(links: provider, retryClock: ManualClock())
        let store = MobileShellComposite(workspaces: [])
        bridge.attach(to: store)
        bridge.setAdmittedMachines([Self.machine])
        await settle(until: { store.externalHostSummaries.first?.status == .connected })
        return (bridge, provider, store)
    }

    /// A workspace's id as the bridge publishes it.
    private func row(_ remoteWorkspaceID: String) -> MobileWorkspacePreview.ID {
        MobileWorkspacePreview.ID(rawValue: CloudAddress(machineID: "vm-1", component: remoteWorkspaceID).identifier)
    }

    /// The same workspace's id in the store's list, which scopes ids.
    private func listed(_ remoteWorkspaceID: String, in store: MobileShellComposite) -> MobileWorkspacePreview.ID? {
        store.workspaces.first { $0.rpcWorkspaceID == row(remoteWorkspaceID) }?.id
    }

    @Test("A new workspace is in the rows, with its terminal, when the create returns")
    func createdWorkspaceIsPublished() async {
        let (bridge, _, store) = await makeBridge()

        let created = await bridge.externalHostCreateWorkspace(onHost: Self.hostID)

        #expect(created == row("ws-2"))
        let published = try! #require(store.workspaces.first { $0.rpcWorkspaceID == created })
        #expect(published.terminals.map(\.id.rawValue) == [CloudAddress(machineID: "vm-1", component: "t-2").identifier])
    }

    @Test("A new terminal lands in the workspace it was made from")
    func createdTerminalJoinsItsWorkspace() async {
        let (bridge, _, store) = await makeBridge()

        let surfaceID = await bridge.externalHostCreateTerminal(inWorkspace: row("ws-1"))

        let expected = CloudAddress(machineID: "vm-1", component: "t-2").identifier
        #expect(surfaceID == expected)
        let workspace = try! #require(store.workspaces.first { $0.rpcWorkspaceID == row("ws-1") })
        #expect(workspace.terminals.map(\.id.rawValue).contains(expected))
    }

    @Test("A terminal made from the row of unplaced terminals gets a workspace of its own")
    func terminalFromUnassignedRowGetsAWorkspace() async {
        let (bridge, _, store) = await makeBridge()

        let surfaceID = await bridge.externalHostCreateTerminal(inWorkspace: row(CloudWorkspaceProjector.unassignedWorkspaceID))

        let expected = CloudAddress(machineID: "vm-1", component: "t-2").identifier
        #expect(surfaceID == expected)
        let owner = store.workspaces.first { $0.terminals.contains { $0.id.rawValue == expected } }
        #expect(owner?.rpcWorkspaceID == row("ws-2"))
    }

    @Test("A second New Workspace tap while one runs is refused, not doubled")
    func doubleTapCreatesOnce() async {
        let (_, provider, store) = await makeBridge()
        provider.link.createGate = AsyncStream<Void>.makeStream()

        async let first = store.createExternalHostWorkspace(onHost: Self.hostID)
        // The second tap only proves anything once the first is truly inside
        // the daemon call.
        await settle(until: { provider.link.createWaiters == 1 })
        let second = await store.createExternalHostWorkspace(onHost: Self.hostID)

        guard case .failure(.busy) = second else {
            Issue.record("second create was not refused: \(second)")
            return
        }
        provider.link.createGate?.continuation.finish()
        guard case .success = await first else {
            Issue.record("first create failed")
            return
        }
        #expect(provider.link.createdWorkspaceCount == 1)
    }

    @Test("A refused create reports nothing made")
    func refusedCreate() async {
        let (bridge, provider, _) = await makeBridge()
        provider.link.refuses = true

        #expect(await bridge.externalHostCreateWorkspace(onHost: Self.hostID) == nil)
        #expect(await bridge.externalHostCreateTerminal(inWorkspace: row("ws-1")) == nil)
    }

    @Test("New Terminal on a Cloud workspace goes to the machine and opens the new terminal")
    func storeRoutesNewTerminalToTheMachine() async {
        let (_, _, store) = await makeBridge()
        let expected = MobileTerminalPreview.ID(rawValue: CloudAddress(machineID: "vm-1", component: "t-2").identifier)

        let workspaceID = try! #require(listed("ws-1", in: store))
        store.createTerminal(in: workspaceID)
        await settle(until: { store.selectedTerminalID == expected })

        #expect(store.selectedWorkspaceID == workspaceID)
        #expect(store.selectedTerminalID == expected)
        #expect(store.terminalCreationError == nil)
    }

    @Test("A refused New Terminal says so instead of opening a terminal that does not exist")
    func storeSurfacesARefusedNewTerminal() async {
        let (_, provider, store) = await makeBridge()
        provider.link.refuses = true
        let workspaceID = try! #require(listed("ws-1", in: store))

        store.createTerminal(in: workspaceID)
        await settle(until: { store.terminalCreationError != nil })

        #expect(store.terminalCreationError != nil)
        // The detail screen shows the error only when this matches the
        // workspace's published id, as it does for a Mac's.
        #expect(store.terminalCreationErrorWorkspaceID == row("ws-1"))
        // The Mac path would have selected a placeholder terminal no host
        // serves; the selection must stay on a real one.
        let existing = store.workspaces.first { $0.id == workspaceID }?.terminals.map(\.id) ?? []
        #expect(store.selectedTerminalID.map(existing.contains) ?? true)
    }

    @Test("New Workspace aimed at a machine by id opens the new one")
    func storeCreatesWorkspaceOnTheMachineByID() async {
        let (_, _, store) = await makeBridge()

        let result = await store.createExternalHostWorkspace(onHost: Self.hostID)

        guard case .success = result else {
            Issue.record("create failed: \(result)")
            return
        }
        #expect(store.selectedWorkspaceID == listed("ws-2", in: store))
    }

    @Test("New Workspace beside a Cloud workspace opens the new one on the same machine")
    func storeCreatesWorkspaceOnTheMachine() async {
        let (_, _, store) = await makeBridge()

        let workspaceID = try! #require(listed("ws-1", in: store))
        let result = await store.createExternalHostWorkspace(beside: workspaceID)

        guard case .success = result else {
            Issue.record("create failed: \(result)")
            return
        }
        #expect(store.selectedWorkspaceID == listed("ws-2", in: store))
        #expect(store.selectedTerminalID?.rawValue == CloudAddress(machineID: "vm-1", component: "t-2").identifier)
    }
}
