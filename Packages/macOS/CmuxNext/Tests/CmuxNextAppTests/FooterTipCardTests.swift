import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater

/// BOTTOM-LEFT-CARDS K1 in the app: the window's sidebar shows today's tip
/// with its action's shortcut, the update card replaces it while an update
/// is staged, the user's own run of the feature marks it used (automation
/// does not), and `sidebar.cards.tips` in cmux.json turns it off.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct FooterTipCardTests {
    /// Every catalog tip names a registered action, so Try It always runs.
    @Test func everyTipActionIsRegistered() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let missing = TipCatalog.all.filter { harness.services.registry.descriptor(for: ActionID(rawValue: $0.action)) == nil }
        #expect(missing.isEmpty, "\(missing.map(\.action))")
    }

    @Test func theSidebarShowsTheTipAndTheUpdateCardWins() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let updater = harness.services.updater, model = harness.window.sidebar.model
        updater.debugShowTip("commandPalette")
        for _ in 0..<200 where model.tipCard == nil { await Task.yield() }
        let tip = try #require(model.tipCard)
        #expect(tip.title == TipCatalog.all[0].title && tip.eyebrow == UpdaterService.tipEyebrow)
        #expect(tip.shortcut == harness.services.registry.shortcutDisplay(for: "commandPalette"))
        updater.debugIndicatorPhase = .ready(version: "2")
        for _ in 0..<200 where model.tipCard != nil { await Task.yield() }
        #expect(model.tipCard == nil && model.updateCard != nil, "one card at a time")
    }

    /// A CLI run of a tip's feature does not count as used; Try It runs the
    /// feature through the registry (the shared path) as the user's, and
    /// that run counts.
    @Test func onlyTheUsersOwnRunsCountAndTryItRunsTheFeature() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let updater = harness.services.updater, registry = harness.services.registry
        let saved = TipState(defaults: updater.defaults)
        defer { saved.save(to: updater.defaults) }
        TipState().save(to: updater.defaults)
        updater.tipState = TipState()
        var ran: [(ActionID, ActionOrigin)] = []
        let observer = registry.runObserver
        registry.runObserver = { id, invocation in
            ran.append((id, invocation.origin))
            observer?(id, invocation)
        }
        registry.perform("splitRight", invocation: ActionInvocation(origin: .cli))
        #expect(ran.contains { $0.0 == "splitRight" && $0.1 == .cli })
        #expect(!updater.tipState.usedActions.contains("splitRight"), "automation is not the user using the feature")
        updater.debugShowTip("splitRight")
        harness.window.sidebar.handle(.tryTip("splitRight"))
        #expect(ran.contains { $0.0 == "splitRight" && $0.1 == .user })
        #expect(updater.tipState.usedActions.contains("splitRight"))
        #expect(updater.tip == nil)
    }

    @Test func theSettingTurnsTipsOff() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-next-tips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"sidebar": {"cards": {"tips": false}}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: harness.services.registry, design: DesignSettings(), fileURL: url)
        settings.start()
        defer { settings.stop() }
        let updater = harness.services.updater
        updater.follow(settings)
        defer { updater.settingsObservation?.cancel() }
        for _ in 0..<200 where updater.tipsEnabled { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!updater.tipsEnabled)
        #expect(updater.tip == nil)
        #expect(harness.window.sidebar.model.tipCard == nil)
    }
}
