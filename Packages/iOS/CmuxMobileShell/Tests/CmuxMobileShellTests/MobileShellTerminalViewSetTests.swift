import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func mountedTerminalsAreDeclaredToTheMacAndUnmountingRemovesThem() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities([
        "events.v1", "terminal.render_grid.v1", "terminal.replay.v1",
        MobileTerminalViewSet.capability,
    ])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = UUID().uuidString

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    let declared = try await pollUntil {
        await router.requests(for: MobileTerminalViewSet.method).last?.surfaceIDs == [surfaceID]
    }
    #expect(declared, "a mounted terminal must be declared so the Mac renders it")

    collector.unmount()
    let withdrawn = try await pollUntil {
        await router.requests(for: MobileTerminalViewSet.method).last?.surfaceIDs == []
    }
    #expect(withdrawn, "an unmounted terminal must leave the declaration")
}

@MainActor
@Test func macsWithoutTheCapabilityNeverReceiveADeclaration() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = UUID().uuidString
    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    let mounted = try await pollUntil { store.hasTerminalOutputSink(surfaceID: surfaceID) }
    #expect(mounted)
    // Without the capability the sync returns before starting a request, so
    // nothing can be in flight and nothing was ever acknowledged.
    store.syncTerminalViewSet(force: true)
    #expect(store.terminalViewSetSync.inFlight == nil)
    #expect(store.terminalViewSetSync.acknowledgedSurfaceIDs == nil)
    #expect(await router.count(of: MobileTerminalViewSet.method) == 0)
    collector.unmount()
}
