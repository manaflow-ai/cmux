import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The clipboard-read service follows the local store with one `.sameTurn` FrameObservation (p04-input-026): the
/// changes of one turn reach the broker once, on the next main run loop pass, with no display frame and no `Task`
/// per change; after `stop()` nothing reaches it.
@MainActor @Suite(.serialized)
struct TerminalClipboardReadServiceTests {
    private static func spinMainRunLoop(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        repeat {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        } while !done() && Date() < end
    }

    private static func started() -> (AppServices, TerminalClipboardReadService) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        _ = services.daemon.store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        let service = TerminalClipboardReadService(services: services)
        service.start()
        return (services, service)
    }

    @Test func theChangesOfOneTurnReachTheBrokerOnceOnTheNextRunLoopPass() {
        let (services, service) = Self.started()
        defer { service.stop() }
        #expect(service.handOffs == 1, "start hands the current state over in its own turn")
        let store = services.daemon.store
        store.apply(.disconnected("first"))
        store.apply(.disconnected("second"))
        #expect(service.handOffs == 1, "a change reached the broker inside its will-set")
        Self.spinMainRunLoop { service.handOffs > 1 }
        #expect(service.handOffs == 2, "\(service.handOffs - 1) hand-offs for two changes in one turn (want 1)")
        var passes = 0
        Self.spinMainRunLoop {
            passes += 1
            return passes == 10
        }
        #expect(service.handOffs == 2, "a hand-off with nothing changed (a re-arm)")
    }

    @Test func nothingReachesTheBrokerAfterStop() {
        let (services, service) = Self.started()
        service.stop()
        services.daemon.store.apply(.disconnected("after stop"))
        var passes = 0
        Self.spinMainRunLoop {
            passes += 1
            return passes == 10
        }
        #expect(service.handOffs == 1)
    }
}
