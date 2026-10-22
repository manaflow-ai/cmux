import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Set Space Terminal Defaults… (`space.setDefaults`) has only optional arguments, so the palette
/// ran it at once with none, and a run with neither `cwd` nor `env` cleared the space's terminal
/// defaults without a word (palette audit). A run with neither argument now asks for the directory
/// in the palette, starting from the current one, and sends nothing; automation that names no
/// argument is refused. A run that names them (both empty clears) still sends one update.
@MainActor @Suite(.serialized) struct SpaceSetDefaultsAskTests {
    struct Fixture {
        let services: AppServices
        /// Commands sent to the local daemon (`update-profile` is the only one these runs send).
        let sends: () -> Int
        let asked: () -> [(ActionID, ActionInvocation, ActionArgumentAsk)]
    }

    /// A daemon with the spaces Default and Work; Work's terminals start in /tmp/work with A=1.
    static func fixture(asker: Bool) throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let daemon = services.machines.local
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        daemon.store.noteHandshake(identity)
        daemon.store.connectionState = .connected(identity)
        var tree = DaemonTree(registryID: "s-local", workspaces: [])
        tree.personal = PersonalState(sessions: [SessionRecord(id: "s-local")], profiles: [
            ProfileSnapshot(id: .defaultProfile, name: "Default", index: 0),
            ProfileSnapshot(id: "work", name: "Work", index: 1, defaults: ProfileDefaults(cwd: "/tmp/work", env: ["A": "1"])),
        ])
        daemon.store.apply(snapshot: tree)
        var sends = 0
        daemon.workTracker = { _ in sends += 1 }
        var asked: [(ActionID, ActionInvocation, ActionArgumentAsk)] = []
        if asker { services.registry.argumentAsker = { asked.append(($0, $1, $2)) } }
        return Fixture(services: services, sends: { sends }, asked: { asked })
    }

    static let work = ActionTargetRef(kind: .profile, id: "work")

    @Test func fromThePaletteWithNoArgumentsItAsksAndClearsNothing() throws {
        let fixture = try Self.fixture(asker: true)
        #expect(fixture.services.registry.perform("space.setDefaults", invocation: ActionInvocation(target: Self.work)))
        #expect(fixture.sends() == 0, "the run sent an update (it cleared the space's terminal defaults)")
        let ask = try #require(fixture.asked().first, "the palette was not asked for the defaults")
        #expect(ask.0 == "space.setDefaults")
        #expect(ask.1.target == Self.work)
        #expect(ask.2 == ActionArgumentAsk(argument: "cwd", initialText: "/tmp/work"))
        // The answer reruns with this invocation plus `cwd`, so the space keeps its environment.
        let env = try #require(ask.1["env"]?.stringValue, "the ask drops the space's env")
        #expect(try JSONSerialization.jsonObject(with: Data(env.utf8)) as? [String: String] == ["A": "1"])
    }

    @Test func automationWithNoArgumentsIsRefusedAndClearsNothing() throws {
        let fixture = try Self.fixture(asker: true)
        let reason = fixture.services.registry.capturingRefusal {
            _ = fixture.services.registry.perform("space.setDefaults", invocation: ActionInvocation(target: Self.work, origin: .cli))
        }
        #expect(reason != nil, "a CLI run with no arguments was not refused")
        #expect(fixture.sends() == 0, "the run sent an update (it cleared the space's terminal defaults)")
        #expect(fixture.asked().isEmpty, "a CLI run opened the palette on the person's screen")
    }

    @Test func namedArgumentsStillSetAndBothEmptyStillClears() throws {
        let fixture = try Self.fixture(asker: true)
        let set = ActionInvocation(target: Self.work, arguments: ["cwd": .string("/tmp/other")], origin: .cli)
        #expect(fixture.services.registry.perform("space.setDefaults", invocation: set))
        #expect(fixture.sends() == 1)
        let clear = ActionInvocation(target: Self.work, arguments: ["cwd": .string(""), "env": .string("")], origin: .cli)
        #expect(fixture.services.registry.perform("space.setDefaults", invocation: clear))
        #expect(fixture.sends() == 2)
        #expect(fixture.asked().isEmpty)
    }
}
