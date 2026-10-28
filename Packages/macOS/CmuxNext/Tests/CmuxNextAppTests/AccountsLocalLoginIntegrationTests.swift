import AppKit
import CmuxNextAccounts
@testable import CmuxNextApp
import CmuxNextCodeRouter
import Foundation
import Testing

/// Accounts must open its provider command even when no existing window has a local pane.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))
struct AccountsLocalLoginIntegrationTests {
    @Test func aProviderCommandCreatesALocalWorkspaceWhenNoWindowCanTakeIt() async throws {
        try await PinnedPageTests.withApp { services, _ in
            for controller in services.windows.controllers { controller.window?.close() }
            try #require(services.windows.controllers.isEmpty)
            let before = Set(services.machines.local.store.workspaces.map(\.id))
            // A harmless stand-in for the provider's login: never touch real credentials.
            let opened = await services.accounts.reauthenticate(.codex, plan: .command(["true"]))
            #expect(opened, "Accounts refused the command because it could not find an existing local pane")
            if opened {
                try await PinnedPageTests.until({
                    services.machines.local.store.workspaces.contains { !before.contains($0.id) && $0.name == "Provider sign-in" }
                }, report: { "the provider command did not create a local workspace" })
            }
        }
    }
}
