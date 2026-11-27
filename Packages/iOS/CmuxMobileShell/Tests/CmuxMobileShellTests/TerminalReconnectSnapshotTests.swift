import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
struct TerminalReconnectSnapshotTests {
    @Test(arguments: [false, true])
    func manualReconnectRefreshesAnOpenTerminalOnAHealthyConnection(
        fromWorkspaceTitle: Bool
    ) async throws {
        let router = LivenessHostRouter()
        let store = try await makeConnectedStore(router: router, box: TransportBox(), clock: TestClock())
        let collector = OutputCollector()
        defer {
            collector.unmount()
            store.disconnectLiveConnection()
        }
        #expect(try await pollUntil { store.terminalEventSubscriptionIsValidated })
        await router.replaceReplayText("before-manual-reconnect")
        collector.mount(store: store, surfaceID: "live-terminal")
        #expect(try await pollUntil { collector.lines.contains("before-manual-reconnect") })
        let selectedWorkspace = store.selectedWorkspaceID
        let selectedTerminal = store.selectedTerminalID
        let client = store.remoteClient
        let subscriptionCount = await router.count(of: "mobile.events.subscribe")
        await router.replaceReplayText("missed-live-output")

        if fromWorkspaceTitle {
            await store.reconnectToMac(
                macDeviceID: store.foregroundMacDeviceID,
                instanceTag: store.activeMacInstanceTag
            )
        } else {
            await store.reconnectOrRefresh()
        }

        #expect(try await pollUntil { collector.lines.contains("missed-live-output") })
        #expect(await router.count(of: "mobile.events.subscribe") > subscriptionCount)
        #expect(store.remoteClient === client, "repair output without replacing a healthy connection")
        #expect(store.connectionState == .connected)
        #expect(store.selectedWorkspaceID == selectedWorkspace)
        #expect(store.selectedTerminalID == selectedTerminal)
    }

    @Test(arguments: [false, true], [false, true])
    func reconnectCatchesUpAfterSubscriptionWithoutReopeningTerminal(
        mountDuringReconnect: Bool,
        renderGridOnly: Bool
    ) async throws {
        let router = LivenessHostRouter()
        if renderGridOnly {
            await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
        }
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        let collector = OutputCollector()
        defer {
            collector.unmount()
            store.disconnectLiveConnection()
            Task { await router.releaseAllHeld() }
        }
        #expect(try await pollUntil {
            store.lastSuccessfulTerminalSubscription?.connectionGeneration == store.connectionGeneration
                && store.lastSuccessfulTerminalSubscription?.listenerID != nil
        })
        if !mountDuringReconnect {
            await router.replaceReplayText("before-disconnect")
            collector.mount(store: store, surfaceID: "live-terminal")
            #expect(try await pollUntil { collector.lines.contains("before-disconnect") })
        }
        let selectedWorkspace = store.selectedWorkspaceID
        let selectedTerminal = store.selectedTerminalID
        store.disconnectLiveConnection()
        await router.dropSubscription()
        let nextSubscription = await router.count(of: "mobile.events.subscribe") + 1
        await router.delaySubscribeRequest(number: nextSubscription)
        await router.replaceReplayText("before-subscription")
        let replayCount = await router.count(of: "mobile.terminal.replay")

        let ticket = try makeTicket(clock: clock)
        #expect(await store.connectPairingURL(try attachURL(for: ticket)))
        #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: nextSubscription))
        if mountDuringReconnect {
            collector.mount(store: store, surfaceID: "live-terminal")
        }

        // No server registration exists yet. A replay here can miss output
        // generated before registration, even if every later event arrives.
        #expect(await router.waitForCount(
            of: "mobile.terminal.replay",
            atLeast: replayCount + 1,
            timeoutNanoseconds: 200_000_000,
            recordIssueOnTimeout: false
        ) == false)
        await router.replaceReplayText("output-during-reconnect")
        await router.releaseAllHeld()

        #expect(try await pollUntil {
            collector.lines.contains("output-during-reconnect")
        }, "the still-mounted terminal must catch output from the subscription gap")
        #expect(store.selectedWorkspaceID == selectedWorkspace)
        #expect(store.selectedTerminalID == selectedTerminal)

        let transport = try #require(box.get())
        if renderGridOnly {
            await transport.deliver(try renderGridEventFrame(
                surfaceID: "live-terminal",
                seq: 100,
                text: "live-after-reconnect",
                columns: 32
            ))
        } else {
            await transport.deliver(try terminalBytesEventFrame(
                surfaceID: "live-terminal",
                seq: 0,
                text: "live-after-reconnect"
            ))
        }
        #expect(try await pollUntil {
            collector.lines.contains { $0.contains("live-after-reconnect") }
        })
    }
}
