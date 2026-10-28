import AppKit
import CmuxNextAccounts
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCodeRouter
import CmuxNextDaemon
import Foundation
import Testing

/// Accounts must open its provider command even when no existing window has a local pane.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))
struct AccountsLocalLoginIntegrationTests {
    @Test func thePaletteAndCLIReachTheLoginWithNoMainWindow() async {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]))
        AppActions.bind(services)
        var work: [ActionWork] = []
        let refusal = services.registry.capturingRefusal {
            work = services.registry.capturingWork {
                _ = services.registry.perform("accounts.reauthenticate", invocation: ActionInvocation(
                    arguments: ["provider": .string("codex")], origin: .cli))
            }
        }
        #expect(refusal == nil)
        #expect(!work.isEmpty, "the action refused before the model could choose a local workspace")
        for task in work { #expect(await task.value == nil) }
    }

    @Test(arguments: [false, true])
    func aProviderLoginCreatesALocalWorkspaceWhenNoWindowCanTakeIt(page: Bool) async throws {
        try await PinnedPageTests.withApp { services, _ in
            for controller in services.windows.controllers { controller.window?.close() }
            try #require(services.windows.controllers.isEmpty)
            let before = Set(services.machines.local.store.workspaces.map(\.id))
            // A harmless stand-in for the provider's login: never touch real credentials.
            let url = try #require(URL(string: "about:blank"))
            let plan: ReauthPlan = page ? .page(url) : .command(["true"])
            let opened = await services.accounts.reauthenticate(.codex, plan: plan)
            #expect(opened, "Accounts refused the login because it could not find an existing local pane")
            if opened {
                try await PinnedPageTests.until({
                    services.machines.local.store.workspaces.contains { !before.contains($0.id) && $0.name == "Provider sign-in" }
                }, report: { "the provider command did not create a local workspace" })
            }
        }
    }
}
