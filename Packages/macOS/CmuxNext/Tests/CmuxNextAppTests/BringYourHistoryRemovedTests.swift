import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextOnboarding
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// Bring your history is gone from cmux-next (David Beyer's Nov 20 feedback: oddly hidden, and it tied memory to
/// Chief only; Lawrence: remove it). No palette row, Settings > Home button, Chief row menu item, first-run page or
/// Set Up cmux row offers it any more, and memory a person already imported stays where it is.
@MainActor @Suite(.serialized) struct BringYourHistoryRemovedTests {
    /// The palette, the Chief row's menu and Settings run registry actions: an unbound action shows in none of them.
    @Test func theAppBindsNoHistoryImportAction() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(!services.registry.isBound("chief.importMemories"))
        #expect(!services.registry.isBound("chief.importMemories.undo"))
    }

    /// No page to open: a first run, the Set Up cmux card or a stale link cannot show it.
    @Test func noHistoryImportPageIsRegistered() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.pages.provider(InternalPageID(rawValue: "import-history")) == nil)
    }

    /// Settings > Home lists no Bring Your History button.
    @Test func settingsHomeOffersNoHistoryImport() {
        #expect(!SettingsSchema.actions(in: .home).contains("chief.importMemories"))
    }

    /// The Set Up cmux card has no chat history row, even on a Mac with other agents' chats.
    @Test func theSetupCardHasNoChatHistoryRow() async throws {
        let suite = "cmux-history-removed-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = FirstRunSetup(defaults: defaults)
        #expect(setup.begin(isFirstRun: true, replacedKeys: FirstRunSetupTests.replaced))
        let provider = SetupCardPageProvider(setup: setup, agents: nil, environment: SetupCardEnvironment(
            account: { (false, nil) }, signInAccount: {}, cliState: { "missing" }, installCLI: { _ in }, openAgents: {},
            screenReader: { false }))
        defer { provider.stop() }
        // The card's start-up reads (all immediate here) settle within a few main-actor turns.
        for _ in 0..<50 { await Task.yield() }
        #expect(provider.cli == "missing")
        let row = provider.state["history"]
        #expect(row == nil || row == .null, "the card offered a chat history row: \(String(describing: row))")
    }
}
