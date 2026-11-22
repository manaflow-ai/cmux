import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// A change of `navigation.historyScope` alone tells the trail's observers (the titlebar buttons
/// re-read canNavigate), with no trail change (history.md 4.2a, R69).
@MainActor
struct LocationTrailScopeWatchTests {
    @Test func aScopeChangeNotifiesObservers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: file)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: file)
        await settings.reload()
        let services = ActionBindingCoverageTests.boundServices()
        var calls = 0
        services.locationTrail.addObserver { calls += 1 }
        services.locationTrail.watchScope(settings: settings)
        for _ in 0..<50 { await Task.yield() }
        #expect(calls == 0, "starting the watch is not a change")
        try await settings.set(.string("window"), at: ["navigation", "historyScope"])
        await settings.reload()
        for _ in 0..<500 where calls == 0 { await Task.yield() }
        #expect(calls >= 1)
    }
}
