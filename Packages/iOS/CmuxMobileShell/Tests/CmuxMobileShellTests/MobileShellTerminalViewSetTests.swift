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
        MobileTerminalViewSetRPC.capability,
    ])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = UUID().uuidString

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    let declared = try await pollUntil {
        await router.requests(for: MobileTerminalViewSetRPC.method).last?.surfaceIDs == [surfaceID]
    }
    #expect(declared, "a mounted terminal must be declared so the Mac renders it")

    collector.unmount()
    let withdrawn = try await pollUntil {
        await router.requests(for: MobileTerminalViewSetRPC.method).last?.surfaceIDs == []
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
    // Give an erroneous declaration time to reach the scripted Mac.
    try await Task.sleep(for: .milliseconds(200))
    #expect(await router.count(of: MobileTerminalViewSetRPC.method) == 0)
    collector.unmount()
}
