import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// App services whose observation hops became FrameObservations: the changes of one turn reach each
/// one once, in its delivery's class, on a scheduler with no display link, and never inside the change's will-set.
/// ``drainMainTurns(rounds:)`` runs the deliveries.
@MainActor @Suite(.serialized)
struct AppObservationDeliveryTests {
    @MainActor @Observable final class Colors {
        var value: TerminalDefaultColors?
    }

    /// A main-thread scheduler with no display link: a post runs on the next main run loop pass.
    private static func work() -> MainWorkScheduler {
        MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in nil }
    }

    /// The browser host asks its provider for fresh credentials once for the connection changes of one turn.
    @Test func theBrowserHostAsksForCredentialsOncePerTurnOfConnectionChanges() async {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: Self.work())
        let host = AppBrowserHost(services: services, installID: "test")
        host.start()
        let store = services.daemon.store
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        store.apply(.disconnected(reason: "dropped"))
        #expect(host.credentialRequests == 0, "a change asked inside its will-set")
        await drainMainTurns()
        #expect(host.credentialRequests == 1, "\(host.credentialRequests) credential requests for one turn's changes (want 1)")
        await drainMainTurns()
        #expect(host.credentialRequests == 1, "a request with nothing changed")
    }

    /// Every daemon gets the terminal colors once for the color changes of one turn.
    @Test func terminalColorsApplyOncePerTurnOfChanges() async {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let colors = Colors()
        let sync = TerminalColorSync(machines: services.machines, on: Self.work()) { colors.value }
        #expect(sync.applies == 1, "init applies in its own turn")
        let dark = TerminalDefaultColors(foreground: "#ffffff", background: "#000000", cursor: nil)
        colors.value = TerminalDefaultColors(foreground: "#000000", background: "#ffffff", cursor: nil)
        colors.value = dark
        #expect(sync.applies == 1, "a change applied inside its will-set")
        await drainMainTurns()
        #expect(sync.applies == 2, "\(sync.applies - 1) applies for two changes in one turn (want 1)")
        #expect(services.machines.daemons.allSatisfy { $0.terminalDefaultColors == dark })
    }

    /// A page hears its connection once per turn of changes, and not at all when the turn ends where it began.
    @Test func aPageHearsItsConnectionOncePerTurnOfChanges() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "page-connection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<html><body></body></html>".utf8).write(to: directory.appending(path: "index.html"))
        let descriptor = PageDescriptor(id: "test.page-connection", resource: "page-connection", processGroup: .solo, namespaces: [])
        let page = try #require(PageWebView(descriptor: descriptor, root: directory, routes: []))
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        let watch = PageConnectionWatch(page: page, store: store, on: Self.work())
        watch.start()
        #expect(watch.handOffs == 1, "start hands the state over in its own turn")
        store.apply(.disconnected(reason: "first"))
        store.apply(.disconnected(reason: "second"))
        #expect(watch.handOffs == 1, "a change reached the page inside its will-set")
        await drainMainTurns()
        #expect(watch.handOffs == 2, "\(watch.handOffs - 1) hand-offs for two changes in one turn (want 1)")
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: false))
        store.apply(.disconnected(reason: "again"))
        await drainMainTurns()
        #expect(watch.handOffs == 2, "a turn that ended disconnected, as it began, told the page again")
        withExtendedLifetime(page) {}
    }
}
