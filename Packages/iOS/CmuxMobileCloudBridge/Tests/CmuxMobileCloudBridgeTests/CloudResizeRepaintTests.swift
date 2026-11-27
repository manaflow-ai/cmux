import CmuxMobileCloud
import CmuxMobileShell
import Foundation
import Testing

@testable import CmuxMobileCloudBridge

/// The repaint contract that keeps a Cloud terminal's screen truthful when
/// the daemon's grid moves away from the one the phone painted (a daemon
/// without viewer-size priority takes another viewer's size): from then on
/// the program repaints partially on the wrong grid, so the bridge must fetch
/// a fresh snapshot instead of trusting the incremental stream.
@MainActor
struct CloudResizeRepaintTests {
    private final class TerminalLink: CloudTerminalLinking, @unchecked Sendable {
        func send(_ bytes: Data) {}
        func resize(cols: Int, rows: Int) {}
        func detach() {}
    }

    private final class MachineLink: CloudMachineLinking, @unchecked Sendable {
        private let lock = NSLock()
        private var _attaches: [String] = []
        private var _sinks: [@Sendable (CloudTerminalOutputEvent) -> Void] = []
        var attaches: [String] { lock.withLock { _attaches } }

        func emit(_ event: CloudTerminalOutputEvent) {
            for sink in lock.withLock({ _sinks }) { sink(event) }
        }

        func loadCatalog() async throws -> (
            workspaces: [CloudWorkspaceSummary],
            terminals: [CloudTerminalSummary]
        ) {
            (
                [CloudWorkspaceSummary(id: "ws-1", name: "api")],
                [CloudTerminalSummary(id: "t-1", workspaceID: "ws-1")]
            )
        }

        func attach(
            terminalID: String,
            output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void
        ) async throws -> any CloudTerminalLinking {
            lock.withLock {
                _attaches.append(terminalID)
                _sinks.append(output)
            }
            output(.snapshot(replay: Data("$ ".utf8), cols: 80, rows: 24))
            return TerminalLink()
        }

        func createWorkspace(name: String?) async -> String? { nil }
        func createTerminal(inWorkspace workspaceID: String, name: String?) async -> String? { nil }
    }

    private final class Provider: CloudMachineLinkProviding {
        let link = MachineLink()
        func link(for machine: CloudMachine) -> (any CloudMachineLinking)? { link }
        func resetLink(for machine: CloudMachine) {}
    }

    private static let machine = CloudMachine(id: "vm-1", provider: "freestyle", status: "running", slug: "sleepy-teal-otter")
    private static let surfaceID = CloudAddress(machineID: "vm-1", component: "t-1").identifier

    private func settle(until condition: () -> Bool, timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    // The bridge holds the store weakly, so the tuple retains it: a dropped
    // store silently discards every delivered event.
    private func makeBridge() async -> (CloudWorkspaceBridge, Provider, ManualClock, MobileShellComposite) {
        let provider = Provider()
        let clock = ManualClock()
        let bridge = CloudWorkspaceBridge(links: provider, retryClock: clock)
        let store = MobileShellComposite(workspaces: [])
        bridge.attach(to: store)
        bridge.setAdmittedMachines([Self.machine])
        await settle(until: { store.externalHostSummaries.first?.status == .connected })
        bridge.externalHostRequestReplay(surfaceID: Self.surfaceID)
        await settle(until: { provider.link.attaches.count == 1 })
        return (bridge, provider, clock, store)
    }

    @Test("A grid change away from the painted one repaints from a fresh snapshot")
    func gridChangeRepaints() async {
        let (_, provider, clock, store) = await makeBridge()

        provider.link.emit(.output(Data("hello".utf8)))
        provider.link.emit(.resized(cols: 60, rows: 24))
        await settle(until: { clock.sleeperCount == 1 })
        clock.advance(by: CloudWorkspaceBridge.resizeRepaintSettle)

        await settle(until: { provider.link.attaches.count == 2 })
        #expect(provider.link.attaches == ["t-1", "t-1"])
        _ = store
    }

    @Test("A resize matching the painted grid repaints nothing")
    func matchingResizeIsQuiet() async {
        let (_, provider, clock, store) = await makeBridge()

        provider.link.emit(.resized(cols: 80, rows: 24))
        for _ in 0..<50 { await Task.yield() }

        #expect(clock.sleeperCount == 0)
        #expect(provider.link.attaches.count == 1)
        _ = store
    }

    @Test("A burst of grid changes costs one repaint after the settle")
    func burstCoalesces() async {
        let (_, provider, clock, store) = await makeBridge()

        for cols in [70, 66, 61, 60] {
            provider.link.emit(.resized(cols: cols, rows: 24))
        }
        // Each delivered change cancels the pending repaint and arms a new
        // one, so wait for the churn to end at exactly one armed sleeper
        // before the clock moves; advancing mid-churn would miss the last
        // rearm and prove nothing about coalescing.
        let churnDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        var stableChecks = 0
        while stableChecks < 200, ContinuousClock.now < churnDeadline {
            await Task.yield()
            stableChecks = clock.sleeperCount == 1 ? stableChecks + 1 : 0
        }
        clock.advance(by: CloudWorkspaceBridge.resizeRepaintSettle)

        await settle(until: { provider.link.attaches.count == 2 })
        for _ in 0..<50 { await Task.yield() }
        #expect(provider.link.attaches.count == 2)
        _ = store
    }
}
