import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The clipboard-read service follows the local store with one `.sameTurn` FrameObservation (p04-input-026): the
/// changes of one turn reach the broker once, on the next main run loop pass, with no display frame and no `Task`
/// per change; a side event in the change's own turn flushes them to the broker first; after `stop()` nothing
/// reaches it.
@MainActor @Suite(.serialized)
struct TerminalClipboardReadServiceTests {
    private static func started() -> (AppServices, TerminalClipboardReadService) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        _ = services.daemon.store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        let service = TerminalClipboardReadService(services: services)
        service.start()
        return (services, service)
    }

    @Test func theChangesOfOneTurnReachTheBrokerOnceOnTheNextRunLoopPass() async {
        let (services, service) = Self.started()
        defer { service.stop() }
        #expect(service.handOffs == 1, "start hands the current state over in its own turn")
        let store = services.daemon.store
        store.apply(.disconnected("first"))
        store.apply(.disconnected("second"))
        #expect(service.handOffs == 1, "a change reached the broker inside its will-set")
        await drainMainTurns()
        #expect(service.handOffs == 2, "\(service.handOffs - 1) hand-offs for two changes in one turn (want 1)")
        await drainMainTurns()
        #expect(service.handOffs == 2, "a hand-off with nothing changed (a re-arm)")
    }

    @Test func aSideEventInTheTurnOfADisconnectReachesTheBrokerAfterTheDisconnect() async {
        let (services, service) = Self.started()
        defer { service.stop() }
        let store = services.daemon.store
        store.apply(.disconnected("dropped"))
        #expect(service.handOffs == 1)
        // No run loop pass between them: the handler hands the disconnect over before the broker sees the event.
        store.sideEvents.deliver(.terminalClipboardReadCancelled(requestID: "r1"))
        #expect(service.handOffs == 2, "the side event reached the broker before the disconnect")
        await drainMainTurns()
        #expect(service.handOffs == 2, "the run loop apply handed the disconnect over again")
    }

    @Test func nothingReachesTheBrokerAfterStop() async {
        let (services, service) = Self.started()
        service.stop()
        services.daemon.store.apply(.disconnected("after stop"))
        await drainMainTurns()
        #expect(service.handOffs == 1)
    }
}
