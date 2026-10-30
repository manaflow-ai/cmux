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
///
/// Follow-ups to #23385: a `cwd` or `env` that is not text (an in-app caller's bool, or the string
/// "true" the socket makes of the CLI's bare `--cwd`) is refused instead of clearing or setting a
/// nonsense directory; Clear Space Terminal Defaults… (`space.clearDefaults`) asks before it clears
/// and automation must pass `confirm`, as every destructive action does.
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
        // The answer reruns with `cwd` alone, which keeps the space's environment
        // (SpaceDefaultsMergeLiveTests checks that on the daemon).
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

    /// Values that are not text: an in-app caller's bool or number (`cwd: true` used to read as no
    /// directory, so the run cleared the defaults), and the string the socket makes of the CLI's bare
    /// `--cwd` (`"true"`, which set a relative directory named "true").
    @Test(arguments: [
        ["cwd": ActionValue.bool(true)],
        ["env": ActionValue.bool(true)],
        ["cwd": ActionValue.int(1)],
        ["cwd": ActionValue.bool(true), "env": ActionValue.string(#"{"B":"2"}"#)],
        ["cwd": ActionValue.string("true")],
        ["cwd": ActionValue.string("relative/dir")],
    ])
    func aValueThatIsNotADirectoryOrTextIsRefusedAndChangesNothing(_ arguments: [String: ActionValue]) throws {
        let fixture = try Self.fixture(asker: true)
        let reason = fixture.services.registry.capturingRefusal {
            _ = fixture.services.registry.perform("space.setDefaults", invocation: ActionInvocation(target: Self.work, arguments: arguments, origin: .cli))
        }
        #expect(reason != nil, "\(arguments) was not refused")
        #expect(fixture.sends() == 0, "\(arguments) sent an update")
        #expect(fixture.asked().isEmpty)
    }

    @Test func aHomeRelativeDirectoryStillSets() throws {
        let fixture = try Self.fixture(asker: true)
        let run = ActionInvocation(target: Self.work, arguments: ["cwd": .string("~/src")], origin: .cli)
        let reason = fixture.services.registry.capturingRefusal { _ = fixture.services.registry.perform("space.setDefaults", invocation: run) }
        #expect(reason == nil)
        #expect(fixture.sends() == 1)
    }

    /// Clear Space Terminal Defaults… from the palette or a key asks first; nothing is sent until
    /// the person confirms.
    @Test func clearDefaultsFromThePaletteAsksBeforeClearing() async throws {
        let fixture = try Self.fixture(asker: true)
        var presented: [ActionID] = []
        fixture.services.registry.confirmationPresenter = { id, _, _ in presented.append(id) }
        let ran = fixture.services.registry.perform("space.clearDefaults", invocation: ActionInvocation(target: Self.work))
        #expect(ran, "the palette run did nothing")
        #expect(presented == ["space.clearDefaults"], "the palette run did not ask for confirmation")
        #expect(fixture.sends() == 0, "the run cleared before the person confirmed")

        let prompt = await DestructiveConfirmation.prompt(for: "space.clearDefaults", ActionInvocation(target: Self.work), fixture.services)
        #expect(prompt != nil, "the confirmation has no question, so it clears without asking")
        // A space with nothing to clear runs at once (nothing is at stake). The fixture's Default
        // space has no terminal defaults; say so, so a fixture change cannot pass this vacuously.
        let defaultSpace = try #require(fixture.services.machines.local.store.profile(.defaultProfile), "the fixture has no Default space")
        let defaultHasNone = defaultSpace.defaults?.isEmpty ?? true
        #expect(defaultHasNone, "the fixture's Default space has terminal defaults: \(String(describing: defaultSpace.defaults))")
        let none = await DestructiveConfirmation.prompt(
            for: "space.clearDefaults", ActionInvocation(target: ActionTargetRef(kind: .profile, id: ProfileID.defaultProfile.rawValue)), fixture.services)
        #expect(none == nil)
    }

    /// The CLI and MCP must pass `confirm` (CLI `--confirm`), as for every destructive action.
    @Test func clearDefaultsFromAutomationNeedsConfirm() throws {
        let fixture = try Self.fixture(asker: true)
        let reason = fixture.services.registry.capturingRefusal {
            _ = fixture.services.registry.perform("space.clearDefaults", invocation: ActionInvocation(target: Self.work, origin: .cli))
        }
        #expect(reason == ActionRegistry.confirmationRequiredReason(for: "space.clearDefaults"))
        #expect(fixture.sends() == 0)
        let confirmed = ActionInvocation(target: Self.work, origin: .cli).confirmed()
        #expect(fixture.services.registry.perform("space.clearDefaults", invocation: confirmed))
        #expect(fixture.sends() == 1, "a confirmed CLI run sent no update")
    }
}
