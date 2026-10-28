import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextAgentPane
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// With `labs.previewFeatures` on, Settings and the sidebar's Lanes item showed Labs, but no agent
/// page did (no session coverage label, no plan card), and turning it off and on again did not
/// help: launch binds the actions before Settings start, and those bindings make the agent tabs,
/// which then never followed cmux.json. Here the app goes through the same order: actions bound,
/// then Settings.
@MainActor
@Suite(.serialized)
struct AgentPageLabsFollowTests {
    @Test func labsReachAnAgentPageWhenTheActionsWereBoundBeforeSettings() async throws {
        // A page source without the bundle (the shared test page, a Debug root override), and no acpmux.
        // Inject the process snapshot into AppServices instead of mutating environ:
        // libghostty retains environ slices after ghostty_init and concurrent test
        // suites must never rewrite that storage.
        let agentPaneEnvironment = AgentPageAppTestRoot.environment.merging(["CMUX_NEXT_AGENT_PANE_MOCK": "1"]) { $1 }
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), agentPaneEnvironment: agentPaneEnvironment)
        AppActions.bind(services)

        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-labs-follow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"labs":{"previewFeatures":true}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        #expect(settings.snapshot.previewFeatures)
        // The case under test: the bindings already made the agent tabs.
        #expect(services.madeAgentTabs != nil)
        services.settings = settings

        try #require(services.agentTabs.canHostChat, "no agent page source")
        let view = try #require(services.agentTabs.standaloneView(seed: AgentPaneSeed(cwd: "/tmp")))
        for _ in 0..<400 where !view.previewFeatures { await Task.yield() }
        #expect(view.previewFeatures, "Labs on in cmux.json, but the agent page did not get preview")

        // Turning Labs off while the app runs reaches the open page too.
        try await settings.set(.bool(false), at: ["labs", "previewFeatures"])
        for _ in 0..<400 where view.previewFeatures { await Task.yield() }
        #expect(!view.previewFeatures, "Labs off in cmux.json, but the open agent page kept preview")
    }
}
