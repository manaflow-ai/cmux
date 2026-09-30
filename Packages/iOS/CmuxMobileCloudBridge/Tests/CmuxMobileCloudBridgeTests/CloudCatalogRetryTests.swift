import CmuxMobileCloud
import CmuxMobileShell
import Foundation
import Testing

@testable import CmuxMobileCloudBridge

/// A machine whose terminal service is unreachable must heal on its own once
/// the service answers, and must never show a raw id or a generic label.
@MainActor
struct CloudCatalogRetryTests {
    private struct Unreachable: Error {}

    /// Fails the first `failures` catalog reads, then serves one terminal.
    private final class FlakyMachineLink: CloudMachineLinking, @unchecked Sendable {
        private let lock = NSLock()
        private var remainingFailures: Int
        private var _reads = 0

        init(failures: Int) { remainingFailures = failures }

        var reads: Int { lock.withLock { _reads } }

        func createWorkspace(name: String?) async -> String? { nil }
        func createTerminal(inWorkspace workspaceID: String, name: String?) async -> String? { nil }

        func loadCatalog() async throws -> (
            workspaces: [CloudWorkspaceSummary],
            terminals: [CloudTerminalSummary]
        ) {
            let fail = lock.withLock { () -> Bool in
                _reads += 1
                guard remainingFailures > 0 else { return false }
                remainingFailures -= 1
                return true
            }
            if fail { throw Unreachable() }
            return (
                [CloudWorkspaceSummary(id: "ws-1", name: "api")],
                [CloudTerminalSummary(id: "t-1", name: "zsh", workspaceID: "ws-1")]
            )
        }

        func attach(
            terminalID: String,
            output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void
        ) async throws -> any CloudTerminalLinking {
            throw Unreachable()
        }
    }

    private final class Provider: CloudMachineLinkProviding {
        var link: FlakyMachineLink
        var isReady = true
        init(link: FlakyMachineLink) { self.link = link }
        func link(for machine: CloudMachine) -> (any CloudMachineLinking)? { isReady ? link : nil }
        func resetLink(for machine: CloudMachine) {}
    }

    private static let machine = CloudMachine(
        id: "vm-04a498bfde6443bd8722b9786280e4ba",
        provider: "freestyle",
        status: "running"
    )

    private func settle(until condition: () -> Bool, iterations: Int = 2_000) async {
        for _ in 0..<iterations {
            if condition() { return }
            await Task.yield()
        }
    }

    private func makeBridge(failures: Int) -> (CloudWorkspaceBridge, Provider, ManualClock, MobileShellComposite) {
        let provider = Provider(link: FlakyMachineLink(failures: failures))
        let clock = ManualClock()
        let bridge = CloudWorkspaceBridge(links: provider, retryClock: clock)
        let store = MobileShellComposite(workspaces: [])
        bridge.attach(to: store)
        bridge.setAdmittedMachines([Self.machine])
        return (bridge, provider, clock, store)
    }

    @Test("An unreachable machine is retried with backoff until its catalog loads")
    func unreachableMachineRetriesUntilConnected() async {
        let (_, provider, clock, store) = makeBridge(failures: 2)

        await settle(until: { store.externalHostSummaries.first?.status == .unavailable && clock.sleeperCount == 1 })
        #expect(provider.link.reads == 1)

        // Nothing is re-read before the delay elapses.
        clock.advance(by: .seconds(4))
        await settle(until: { false }, iterations: 200)
        #expect(provider.link.reads == 1)

        clock.advance(by: .seconds(1))
        await settle(until: { provider.link.reads == 2 && clock.sleeperCount == 1 })
        #expect(provider.link.reads == 2)

        // The second wait is twice as long.
        clock.advance(by: .seconds(9))
        await settle(until: { false }, iterations: 200)
        #expect(provider.link.reads == 2)
        clock.advance(by: .seconds(1))

        await settle(until: { store.externalHostSummaries.first?.status == .connected })
        #expect(store.externalHostSummaries.first?.status == .connected)
        #expect(store.externalHostSummaries.first?.workspaceCount == 1)
        #expect(provider.link.reads == 3)
        #expect(clock.sleeperCount == 0)
    }

    @Test("Losing the tunnel cancels a pending retry")
    func linkLossCancelsPendingRetry() async {
        let (bridge, provider, clock, store) = makeBridge(failures: 5)
        await settle(until: { clock.sleeperCount == 1 })

        provider.isReady = false
        bridge.linksDidBecomeUnavailable()
        await settle(until: { clock.sleeperCount == 0 })
        #expect(clock.sleeperCount == 0)
        #expect(store.externalHostSummaries.first?.status == .reconnecting)

        clock.advance(by: .seconds(120))
        await settle(until: { false }, iterations: 200)
        #expect(provider.link.reads == 1)
    }

    @Test("Retry delays start at five seconds, double, and cap at a minute")
    func retryDelaySchedule() {
        let delays = (1...8).map { CloudWorkspaceBridge.catalogRetryDelay(afterFailures: $0) }
        #expect(delays == [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60), .seconds(60), .seconds(60)])
    }

    @Test("An unnamed machine is shown by its short id, the same everywhere")
    func unnamedMachineGetsItsShortID() async {
        let (_, _, clock, store) = makeBridge(failures: 1)
        await settle(until: { clock.sleeperCount == 1 })
        #expect(Self.machine.preferredName == "vm-04a498bf")
        #expect(store.externalHostSummaries.first?.displayName == "vm-04a498bf")

        let labeled = CloudMachine(id: Self.machine.id, provider: "freestyle", status: "running", displayName: "whimsical-cobalt-butterfly")
        #expect(labeled.preferredName == "whimsical-cobalt-butterfly")
        #expect(CloudMachine(id: "vm-1", provider: "freestyle", status: "running").preferredName == "vm-1")
    }
}
