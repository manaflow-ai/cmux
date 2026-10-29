import CmuxMobileCloud
import CmuxMobileShell
import Foundation
import Testing

@testable import CmuxMobileCloudBridge

/// What a Cloud terminal looks like across a lost link (the app went to the
/// background, the network changed): its rows stay, and the open terminal
/// comes back on its own.
@MainActor
struct CloudReconnectTests {
    private struct Unreachable: Error {}

    private final class TerminalLink: CloudTerminalLinking, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [Data] = []
        var sentText: String {
            lock.withLock { _sent }.map { String(decoding: $0, as: UTF8.self) }.joined()
        }
        func send(_ bytes: Data) { lock.withLock { _sent.append(bytes) } }
        func resize(cols: Int, rows: Int) {}
        func detach() {}
    }

    private final class MachineLink: CloudMachineLinking, @unchecked Sendable {
        private let lock = NSLock()
        private var _attaches: [String] = []
        private var _failCatalog = false
        var attaches: [String] { lock.withLock { _attaches } }
        var failCatalog: Bool {
            get { lock.withLock { _failCatalog } }
            set { lock.withLock { _failCatalog = newValue } }
        }

        func createWorkspace(name: String?) async -> String? { nil }
        func createTerminal(inWorkspace workspaceID: String, name: String?) async -> String? { nil }

        func loadCatalog() async throws -> (
            workspaces: [CloudWorkspaceSummary],
            terminals: [CloudTerminalSummary]
        ) {
            if failCatalog { throw Unreachable() }
            return (
                [CloudWorkspaceSummary(id: "ws-1", name: "api")],
                [CloudTerminalSummary(id: "t-1", name: "zsh", workspaceID: "ws-1")]
            )
        }

        let terminalLink = TerminalLink()

        func attach(
            terminalID: String,
            output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void
        ) async throws -> any CloudTerminalLinking {
            lock.withLock { _attaches.append(terminalID) }
            output(.snapshot(replay: Data("$ ".utf8), cols: 80, rows: 24))
            return terminalLink
        }
    }

    private final class Provider: CloudMachineLinkProviding {
        let link = MachineLink()
        var isReady = true
        var resets: [String] = []
        func link(for machine: CloudMachine) -> (any CloudMachineLinking)? { isReady ? link : nil }
        func resetLink(for machine: CloudMachine) { resets.append(machine.id) }
    }

    private static let machine = CloudMachine(id: "vm-1", provider: "freestyle", status: "running", slug: "sleepy-teal-otter")
    private static let surfaceID = CloudAddress(machineID: "vm-1", component: "t-1").identifier

    private func settle(
        until condition: () -> Bool,
        timeout: Duration = .seconds(10)
    ) async {
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

    private func terminalIDs(_ store: MobileShellComposite) -> [String] {
        store.workspaces.flatMap { $0.terminals.map(\.id.rawValue) }
    }

    @Test("Losing the link keeps the machine's rows and terminals, as reconnecting")
    func linkLossKeepsRows() async {
        let (bridge, provider, store) = await makeBridge()
        #expect(terminalIDs(store) == [Self.surfaceID])

        provider.isReady = false
        bridge.linksDidBecomeUnavailable()

        #expect(store.externalHostSummaries.first?.status == .reconnecting)
        // An emptied row would strand an open terminal: its view resolves its
        // surface through these rows before it restarts output.
        #expect(terminalIDs(store) == [Self.surfaceID])
    }

    @Test("A failed catalog read keeps the last rows, as unavailable")
    func failedReadKeepsRows() async {
        let (bridge, provider, store) = await makeBridge()
        provider.link.failCatalog = true
        bridge.refreshCatalog(for: Self.machine)
        await settle(until: { store.externalHostSummaries.first?.status == .unavailable })

        #expect(store.externalHostSummaries.first?.status == .unavailable)
        #expect(terminalIDs(store) == [Self.surfaceID])
    }

    @Test("The open terminal re-attaches by itself when its machine's link returns")
    func openTerminalReattachesAfterLinkReturns() async {
        let (bridge, provider, _) = await makeBridge()
        bridge.externalHostRequestReplay(surfaceID: Self.surfaceID)
        await settle(until: { provider.link.attaches.count == 1 })

        provider.isReady = false
        bridge.linksDidBecomeUnavailable()
        provider.isReady = true
        bridge.refreshCatalog(for: Self.machine)

        // No keystroke and no remount: the returning link alone brings the
        // live screen back.
        await settle(until: { provider.link.attaches.count == 2 })
        #expect(provider.link.attaches == ["t-1", "t-1"])
    }

    @Test("A command typed while the link is away is delivered when it returns")
    func inputTypedWhileLinkAwayIsDelivered() async {
        let (bridge, provider, store) = await makeBridge()
        bridge.externalHostRequestReplay(surfaceID: Self.surfaceID)
        await settle(until: { provider.link.attaches.count == 1 })

        provider.isReady = false
        bridge.linksDidBecomeUnavailable()
        // The user keeps typing while the tunnel comes back; the composer has
        // already accepted this text, so it must not vanish.
        store.sendTerminalRawInput(Data("make test\n".utf8), surfaceID: Self.surfaceID)

        provider.isReady = true
        bridge.refreshCatalog(for: Self.machine)
        await settle(until: { provider.link.terminalLink.sentText.contains("make test") })
        #expect(provider.link.terminalLink.sentText == "make test\n")
    }

    @Test("A repaint asked for while the link is down happens once it returns")
    func replayWhileDownAttachesOnReturn() async {
        let (bridge, provider, _) = await makeBridge()
        provider.isReady = false
        bridge.linksDidBecomeUnavailable()

        bridge.externalHostRequestReplay(surfaceID: Self.surfaceID)
        await settle(until: { false }, timeout: .milliseconds(20))
        #expect(provider.link.attaches.isEmpty)

        provider.isReady = true
        bridge.refreshCatalog(for: Self.machine)
        await settle(until: { provider.link.attaches.count == 1 })
        #expect(provider.link.attaches == ["t-1"])
    }

    @Test("Reconnect on a Cloud workspace re-dials its machine and repaints the open terminal")
    func reconnectRedialsAndRepaints() async {
        let (bridge, provider, store) = await makeBridge()
        bridge.externalHostRequestReplay(surfaceID: Self.surfaceID)
        await settle(until: { provider.link.attaches.count == 1 })

        await store.reconnectToMac(macDeviceID: CloudAddress(machineID: "vm-1").identifier)
        await settle(until: { provider.link.attaches.count == 2 })

        // The paired-Mac path would have tried to switch its foreground
        // connection to a machine it does not know.
        #expect(provider.resets == ["vm-1"])
        #expect(provider.link.attaches == ["t-1", "t-1"])
    }

    @Test("Choosing a Cloud machine switches no Mac connection")
    func choosingACloudMachineSwitchesNothing() async {
        let (_, _, store) = await makeBridge()
        #expect(await store.switchToMac(macDeviceID: CloudAddress(machineID: "vm-1").identifier))
    }
}
