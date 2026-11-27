import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// Delete Space… on the only space (Leo, 2026-11-02: "what happens if you delete your one and only space???"). The
/// daemon keeps the Default space, so the last space is never deleted, but the space menu offered Delete Space…
/// enabled and only refused after the click. It is now dimmed with its reason ("This is your only space"), and the
/// palette, CLI and MCP refuse with the same reason before the confirmation and without sending anything.
/// The handler no longer checks the Default space itself, so the second test also holds the Default refusal.
@MainActor @Suite(.serialized) struct SpaceDeleteOnlySpaceTests {
    /// A local daemon whose spaces are `profiles`; the count of commands sent to it.
    static func fixture(_ profiles: [ProfileSnapshot]) throws -> (AppServices, () -> Int) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let daemon = services.machines.local
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        daemon.store.noteHandshake(identity)
        daemon.store.connectionState = .connected(identity)
        var tree = DaemonTree(registryID: "s-local", workspaces: [])
        tree.personal = PersonalState(sessions: [SessionRecord(id: "s-local")], profiles: profiles)
        daemon.store.apply(snapshot: tree)
        var sends = 0
        daemon.workTracker = { _ in sends += 1 }
        return (services, { sends })
    }

    static func target(_ id: ProfileID) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .profile, id: id.rawValue))
    }

    @Test func theOnlySpaceIsDimmedWithItsReasonAndRefusedEverywhere() throws {
        let (services, sends) = try Self.fixture([ProfileSnapshot(id: .defaultProfile, name: "Home", index: 0)])
        let registry = services.registry
        let invocation = Self.target(.defaultProfile)
        #expect(ActionTargetReasons.reason(for: "space.delete", invocation: invocation, in: registry) == RefusalStrings.onlySpaceCannotBeDeleted,
                "the space menu offers Delete Space… on the only space with no reason")
        #expect(!ActionTargetReasons.canPerform("space.delete", invocation: invocation, in: registry),
                "Delete Space… on the only space is enabled")
        var cli = invocation
        cli.origin = .cli
        cli.arguments["confirm"] = .bool(true)
        let refusal = registry.capturingRefusal { _ = registry.perform("space.delete", invocation: cli) }
        #expect(refusal == RefusalStrings.onlySpaceCannotBeDeleted, "a CLI delete of the only space reports \(refusal ?? "success")")
        #expect(sends() == 0, "a delete of the only space reached the daemon")
    }

    @Test func otherSpacesStayDeletableAndDefaultSaysWhy() throws {
        let (services, _) = try Self.fixture([
            ProfileSnapshot(id: .defaultProfile, name: "Default", index: 0),
            ProfileSnapshot(id: "work", name: "Work", index: 1),
        ])
        let registry = services.registry
        #expect(ActionTargetReasons.reason(for: "space.delete", invocation: Self.target("work"), in: registry) == nil)
        #expect(ActionTargetReasons.canPerform("space.delete", invocation: Self.target("work"), in: registry))
        #expect(ActionTargetReasons.reason(for: "space.delete", invocation: Self.target(.defaultProfile), in: registry)
            == RefusalStrings.defaultSpaceCannotBeDeleted)
    }
}
