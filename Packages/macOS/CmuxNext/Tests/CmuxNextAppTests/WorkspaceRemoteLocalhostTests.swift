import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// cx-d0d.41: whose localhost a workspace's browser tabs reach is the person's own choice, kept
/// in personal state. A palette run sets it at once; a command's run (the CLI) changes it only
/// after the person approves it on a native sheet, and a declined sheet changes nothing. Runs
/// against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct WorkspaceRemoteLocalhostTests {
    static let action: ActionID = "workspace.setRemoteLocalhost"

    @Test func thePersonsChoiceWinsAndACommandNeedsTheirApproval() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let workspace = try #require(services.daemon.store.workspaces.first { $0.screens.contains { !$0.panes.isEmpty } })
            let target = ActionTargetRef(kind: .workspace, id: workspace.id)
            let localhost = services.remoteLocalhost
            let stored = {
                WindowProfiles.qualified(workspace.id, machines: services.machines).flatMap {
                    services.machines.local.store.personal.workspace(session: $0.session, key: $0.key)?.remoteLocalhost
                }
            }
            func invocation(_ choice: String, _ origin: ActionOrigin) -> ActionInvocation {
                ActionInvocation(target: target, arguments: ["localhost": .string(choice)], origin: origin)
            }
            /// Runs as a command and answers its sheet; returns the run's failure.
            @MainActor func command(_ choice: String, approve: Bool) async throws -> ActionWorkFailure? {
                let work = services.registry.capturingWork { _ = services.registry.perform(Self.action, invocation: invocation(choice, .cli)) }
                try #require(work.count == 1, "a command's run waits for the person")
                let title = ConfirmationStrings.remoteLocalhostTitle
                try await PasswordManagerRouteTests.until({ CmuxDialogCenter.shared.records.contains { $0.spec.title == title } })
                let sheet = try #require(CmuxDialogCenter.shared.records.last { $0.spec.title == title })
                let answered = approve
                    ? CmuxDialogCenter.shared.press(sheet.id, button: DestructiveConfirmation.confirmID)
                    : CmuxDialogCenter.shared.key(.escape, in: sheet.id)
                #expect(answered)
                return await work[0].value
            }
            defer { CmuxDialogCenter.shared.dismissAll() }

            #expect(localhost.isEnabled(workspace: workspace.id), "browser.remoteLocalhost is on by default")

            // The palette: the person's own run applies at once.
            #expect(services.registry.perform(Self.action, invocation: invocation("thisMac", .user)))
            try await PasswordManagerRouteTests.until({ stored() == false }, report: { "stored \(String(describing: stored()))" })
            #expect(!localhost.isEnabled(workspace: workspace.id), "the person's choice overrides the setting")

            // A command the person declines changes nothing.
            let declined = try await command("machine", approve: false)
            #expect(declined?.refusal == .unavailable, "a declined sheet refuses the run: \(String(describing: declined))")
            try await Task.sleep(for: .milliseconds(300))
            #expect(stored() == false)

            // A command the person approves applies.
            let approved = try await command("machine", approve: true)
            #expect(approved == nil, "\(String(describing: approved))")
            try await PasswordManagerRouteTests.until({ stored() == true }, report: { "stored \(String(describing: stored()))" })
            #expect(localhost.isEnabled(workspace: workspace.id))

            // Follow Settings clears the choice.
            #expect(services.registry.perform(Self.action, invocation: invocation("setting", .user)))
            try await PasswordManagerRouteTests.until({ stored() == nil }, report: { "stored \(String(describing: stored()))" })
        }
    }
}
