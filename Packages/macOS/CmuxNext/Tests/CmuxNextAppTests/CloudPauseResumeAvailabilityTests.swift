import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// Pause Machine and Resume Machine follow the machine's state: a paused machine's menu offers
/// Resume and not Pause, a running or starting one's offers Pause and not Resume, and the palette
/// refuses the one that does not apply, with why. Before, both were offered whatever the state.
/// A CLI, MCP or script run is not refused on the app's record (both calls are idempotent on the
/// server, and the record of a machine with no link may be stale), so the server decides.
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

    @Test func aPausedMachineOffersResumeAndNotPause() {
        let f = Self.fixture(.paused)
        let ids = Self.menuIDs(f.services, f.session)
        #expect(ids.contains(Self.resume), "a paused machine's menu leaves out Resume: \(ids)")
        #expect(!ids.contains(Self.pause), "a paused machine's menu offers Pause: \(ids)")

        let run = ActionInvocation(target: Self.target(f.session))
        #expect(Self.reason(f.services, Self.pause, run) != nil, "Pause on a paused machine is not refused")
        #expect(Self.reason(f.services, Self.resume, run) == nil)
    }

    @Test(arguments: [CloudMachine.Status.running, .provisioning])
    func aLiveMachineOffersPauseAndNotResume(status: CloudMachine.Status) {
        let f = Self.fixture(status)
        let ids = Self.menuIDs(f.services, f.session)
        #expect(ids.contains(Self.pause), "a \(status) machine's menu leaves out Pause: \(ids)")
        #expect(!ids.contains(Self.resume), "a \(status) machine's menu offers Resume: \(ids)")

        let run = ActionInvocation(target: Self.target(f.session))
        #expect(Self.reason(f.services, Self.resume, run) != nil, "Resume on a \(status) machine is not refused")
        #expect(Self.reason(f.services, Self.pause, run) == nil)
    }

    /// The palette runs with no target: the machine it acts on (the window's, else the only one) decides.
    @Test func thePalettesTargetlessRunIsJudgedOnTheMachineItActsOn() {
        let paused = Self.fixture(.paused)
        #expect(Self.reason(paused.services, Self.pause, ActionInvocation()) != nil)
        #expect(Self.reason(paused.services, Self.resume, ActionInvocation()) == nil)

        let running = Self.fixture(.running)
        #expect(Self.reason(running.services, Self.resume, ActionInvocation()) != nil)
        #expect(Self.reason(running.services, Self.pause, ActionInvocation()) == nil)
    }

    /// A machine whose state the app cannot tell (failed, unknown) keeps both: the server decides.
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
