import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Cached API status can lag server idle-pause and app-link resume. Commands remain
/// idempotent; only a live daemon connection can remove redundant Resume from the menu.
@MainActor @Suite(.serialized)
struct CloudPauseResumeAvailabilityTests {
    static let pause: ActionID = "cloudPauseMachine"
    static let resume: ActionID = "cloudResumeMachine"

    static func fixture(_ status: CloudMachine.Status) -> (services: AppServices, session: CloudMachineSession) {
        let services = MachineIconTests.services()
        AppActions.bind(services)
        let session = MachineIconTests.cloudMachine(services, id: "vm-pause-\(UUID().uuidString.prefix(8))")
        session.machine.status = status
        return (services, session)
    }

    static func target(_ session: CloudMachineSession) -> ActionTargetRef {
        ActionTargetRef(kind: .machine, id: session.machineID)
    }

    /// The action ids the machine's sidebar menu shows (its folders included).
    static func menuIDs(_ services: AppServices, _ session: CloudMachineSession) -> [ActionID] {
        let menu = services.registry.makeContextMenu(for: .cloudMachine, target: target(session), implied: .cloudWorkspace)
        return leafItems(menu).compactMap { ActionRegistry.menuRun(of: $0)?.id }
    }

    /// The target reason a run of `id` gets (the sign-in reason aside, which this fixture lacks).
    static func reason(_ services: AppServices, _ id: ActionID, _ invocation: ActionInvocation) -> String? {
        services.registry.action(for: id)?.targetUnavailableReason?(invocation)
    }

    /// The server idle-paused a machine whose last API record still says running.
    @Test(arguments: [CloudMachine.Status.running, .provisioning])
    func staleRunningRecordKeepsResumeAvailable(status: CloudMachine.Status) {
        let f = Self.fixture(status)
        let ids = Self.menuIDs(f.services, f.session)
        #expect(ids.contains(Self.pause) && ids.contains(Self.resume))
        let run = ActionInvocation(target: Self.target(f.session))
        #expect(Self.reason(f.services, Self.resume, run) == nil)
        #expect(Self.reason(f.services, Self.resume, ActionInvocation()) == nil)
    }

    /// The app link resumed a machine without refreshing its paused API record.
    @Test func stalePausedRecordKeepsPauseAvailable() {
        let f = Self.fixture(.paused)
        let ids = Self.menuIDs(f.services, f.session)
        #expect(ids.contains(Self.pause) && ids.contains(Self.resume))
        let run = ActionInvocation(target: Self.target(f.session))
        #expect(Self.reason(f.services, Self.pause, run) == nil)
        #expect(Self.reason(f.services, Self.pause, ActionInvocation()) == nil)
    }

    @Test(arguments: [CloudMachine.Status.paused, .running, .unknown])
    func aLiveDaemonHidesOnlyResumeAndNeverRefusesCommands(status: CloudMachine.Status) async throws {
        let f = Self.fixture(status)
        let identity = CloudCLITargetTests.fullIdentity()
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-pause-menu-\(UUID().uuidString).sock"))
        f.session.daemon.start(first: { .success((connection, identity)) }, makeConnection: { connection })
        defer { f.session.daemon.shutdownConnection() }
        await f.session.daemon.firstConnection()
        #expect(f.session.daemon.connection != nil)
        f.session.daemon.store.connectionState = .connected(identity)
        let ids = Self.menuIDs(f.services, f.session)
        #expect(ids.contains(Self.pause))
        #expect(!ids.contains(Self.resume))
        let run = ActionInvocation(target: Self.target(f.session))
        #expect(Self.reason(f.services, Self.pause, run) == nil)
        #expect(Self.reason(f.services, Self.resume, run) == nil)
    }

    @Test func aKeptHandshakeWithoutAConnectionDoesNotHideResume() {
        let f = Self.fixture(.running)
        f.session.daemon.store.connectionState = .connected(CloudCLITargetTests.fullIdentity())
        #expect(f.session.daemon.connection == nil)
        #expect(Self.menuIDs(f.services, f.session).contains(Self.resume))
    }

    @Test(arguments: [CloudMachine.Status.failed, .unknown])
    func aMachineInAnUnclearStateOffersBoth(status: CloudMachine.Status) {
        let f = Self.fixture(status)
        let ids = Self.menuIDs(f.services, f.session)
        #expect(ids.contains(Self.pause) && ids.contains(Self.resume), "\(status): \(ids)")
    }

    @Test(arguments: [ActionOrigin.cli, .mcp, .script])
    func aRunFromOutsideTheAppIsLeftToTheServer(origin: ActionOrigin) {
        for status in [CloudMachine.Status.paused, .running] {
            let f = Self.fixture(status)
            let run = ActionInvocation(target: Self.target(f.session), origin: origin)
            #expect(Self.reason(f.services, Self.pause, run) == nil, "\(origin) pause on \(status)")
            #expect(Self.reason(f.services, Self.resume, run) == nil, "\(origin) resume on \(status)")
        }
    }

    private static func leafItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in item.submenu.map(leafItems) ?? (item.isSeparatorItem ? [] : [item]) }
    }
}
