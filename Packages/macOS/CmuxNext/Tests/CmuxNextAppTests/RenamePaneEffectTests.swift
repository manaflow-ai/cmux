import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Rename Pane at its action entrypoint (review 2 of pl-instant-swift): the run hands the registry
/// its store intent's effect, so a refusal reaches the caller as the effect's failure, the way the
/// screen renames report one. Before, a pane whose machine had no connection was refused by a
/// separate `ctx.connection()` guard that read the active daemon, not the pane's own, and the run
/// returned `.done` with no work: a capturing caller got no failure from the effect.
///
/// No daemon runs here, so the store intent itself (it shows in the input's turn and leaves the
/// log on a refusal) is covered by PaneScreenMetadataIntentTests, not this suite.
@MainActor @Suite(.serialized)
struct RenamePaneEffectTests {
    @Test func aRenameOnAMachineWithNoConnectionIsTheEffectsReportedFailure() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.machines.local.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "shell", screens: [
                ScreenSnapshot(id: 1, layout: .leaf(1),
                               panes: [PaneSnapshot(id: 1, name: "old", tabs: [TabSnapshot(surface: 1, kind: .pty, title: "zsh", url: "")])]),
            ]),
        ]))
        let pane = try #require(services.machines.local.store.workspaces.flatMap(\.screens).flatMap(\.panes).first)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.id), arguments: ["name": .string("logs")], origin: .cli)

        var work: [ActionWork] = []
        let refusal = services.registry.capturingRefusal {
            work = services.registry.capturingWork { _ = services.registry.perform("renamePane", invocation: invocation) }
        }
        #expect(refusal == nil, "refused before the effect: \(String(describing: refusal))")
        #expect(work.count == 1, "the store intent's send is the run's tracked remote half")
        var failures: [ActionWorkFailure?] = []
        for task in work { failures.append(await task.value) }
        let failure = try #require(failures.first ?? nil, "no failure for a rename on a machine with no connection")
        #expect(failure.message.contains("rename-pane"), "failure: \(failure.message)")
        #expect(pane.name == "old", "a refused rename leaves the old name")
        #expect(services.registry.hiddenWaitRuns["renamePane"] == nil, "the store intent is not a hidden wait")
    }
}
