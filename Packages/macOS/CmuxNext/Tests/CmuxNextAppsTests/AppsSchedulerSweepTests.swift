import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Observation
import Testing
@testable import CmuxNextApps

/// The CmuxNextApps follows of the p06 file-group sweep 343 (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// rule 9): each is a ``ServiceObservation`` in its class, not a main-inherited `ObservationStream` task. The
/// current value applies before the follow's start returns, and a burst of changes posts one flush in the class.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppsSchedulerSweepTests {
    private let owner: ResourceID = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    /// Automation class (the daemon's remote routing): start submits the snapshot it reads at once, and a burst of
    /// registry changes is one automation task that publishes only the last snapshot.
    @Test func machineCatalogBurstPublishesOnceInTheAutomationClass() async throws {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let writer = CatalogTestWriter()
        var events = writer.attempts.makeAsyncIterator()
        let registry = CatalogTestRegistry(MachineCatalogSource(owner: owner, writer: writer, epoch: 1, machines: []))
        let publisher = MachineCatalogPublisher(source: { registry.value }, on: work)
        defer { publisher.stop() }
        publisher.start()
        #expect(publisher.current == registry.value, "start did not submit the current snapshot in its own turn")
        #expect(try #require(await events.next()).sequence == 1)
        await publisher.sending?.value

        registry.value = MachineCatalogSource(owner: owner, writer: writer, epoch: 2, machines: [])
        registry.value = MachineCatalogSource(owner: owner, writer: writer, epoch: 3, machines: [])
        #expect(work.postedCount(.automation) == 1, "a burst of registry changes posted more than one flush")
        #expect(work.postedCount(.visible) == 0, "the publisher's follow flushed in the visible class")
        let last = try #require(await events.next())
        #expect(last.sequence == 1, "the burst's last lease did not start its own sequence")
        await publisher.sending?.value
        #expect(await writer.requests.count == 2, "a snapshot the burst replaced was published")
    }

    /// Automation class (agents' inventory reads): the registry follow posts one automation reconcile per burst, and
    /// stop cancels it.
    @Test func inventoryRouteBurstPostsOneAutomationReconcile() {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let registry = SweepRouteRegistry()
        let bridge = AgentInventoryProviderBridge(on: work) {
            _ = registry.revision
            return []
        }
        bridge.start()
        #expect(work.postedCount(.automation) == 0, "start posted work instead of reconciling in its own turn")
        registry.revision += 1
        registry.revision += 1
        #expect(work.postedCount(.automation) == 1, "a burst of registry changes posted more than one reconcile")
        bridge.stop()
        #expect(bridge.slots.isEmpty)
    }

    /// Visible class (the hover card coordinator redraws the card): the card's scene follow calls its owner once per
    /// burst in one posted visible task, never in the change's turn, and not after release.
    @Test func hoverCardSceneBurstNotifiesOnceInTheVisibleClass() {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let client = AppsClient(transport: SweepAppsTransport(), bundleImages: AppBundleImageCache())
        let mount = client.mount(SidebarCustomizationService.userApp,
                                 implementation: AppImplementation(interface: SidebarCustomizationService.hoverCardInterface),
                                 surface: "hoverCard")
        let card = AppHoverCardContent(mount: mount, client: client, mainWork: work)
        let changes = SweepCounter()
        card.onChange = { changes.count += 1 }
        mount.model.status = .ready
        mount.model.status = .failed("render failed")
        #expect(changes.count == 0, "the card's follow applied in the change's turn")
        #expect(work.postedCount(.visible) == 1, "a burst of scene changes posted more than one flush")
        card.release()
        #expect(changes.count == 0)
    }
}

@MainActor @Observable
private final class SweepRouteRegistry {
    var revision = 0
}

@MainActor
private final class SweepCounter {
    var count = 0
}

/// A supervisor that is never reachable: mounts show the reason and nothing is sent.
@MainActor
private final class SweepAppsTransport: AppsTransport {
    private static let refused = AppsTransportError(message: "not connected", connectionLost: true)
    let availability: AppsAvailability = .unavailable(.notConnected)
    var onEvent: ((AppsTransportEvent) -> Void)?

    func start() {}
    func list() async throws(AppsTransportError) -> AppsListReply { throw Self.refused }
    func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
        throw Self.refused
    }
    func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {
        throw Self.refused
    }
    func unmount(mountID: String) async throws(AppsTransportError) { throw Self.refused }
    func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {
        throw Self.refused
    }
    func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
        throw Self.refused
    }
    func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { throw Self.refused }
}
