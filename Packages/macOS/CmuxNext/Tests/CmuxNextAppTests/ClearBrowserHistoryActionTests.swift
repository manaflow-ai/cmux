import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import Foundation
import Testing

/// Clear Browser History (`palette.browserClearHistory`, the palette and
/// `cmux browser clear-history`): it runs instead of showing a greyed-out
/// reason, and clears the page visits of one browser profile over every
/// time range by default, leaving other profiles alone.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct ClearBrowserHistoryActionTests {
    @Test func clearBrowserHistoryIsAvailable() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.action(for: "palette.browserClearHistory") != nil)
        #expect(services.registry.unavailableReason(for: "palette.browserClearHistory") == nil,
                "Clear Browser History is still greyed out")
    }

    @Test func clearBrowserHistoryRemovesAllOfOneProfilesVisits() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let name = "Clear History \(UUID().uuidString.prefix(8))"
        let other = "Keep History \(UUID().uuidString.prefix(8))"
        try services.browserProfiles.createProfileNow(name: name, color: nil, icon: nil)
        try services.browserProfiles.createProfileNow(name: other, color: nil, icon: nil)
        let record = try #require(services.browserProfiles.ordered.first { $0.name == name })
        let kept = try #require(services.browserProfiles.ordered.first { $0.name == other })
        defer {
            try? services.browserProfiles.delete(record.id)
            try? services.browserProfiles.delete(kept.id)
        }
        let page = try #require(URL(string: "https://clear-history-test.example/old"))
        // Three days old: the default range is all time, not the last hour.
        let old = Date().addingTimeInterval(-3 * 86_400)
        let history = services.cache.history(for: record.engineProfile)
        let keptHistory = services.cache.history(for: kept.engineProfile)
        history.recordVisit(url: page, title: "Old", at: old)
        keptHistory.recordVisit(url: page, title: "Old", at: old)

        let run = ActionInvocation(arguments: ["browserProfile": .string(record.id)]).confirmed()
        #expect(services.registry.perform("palette.browserClearHistory", invocation: run))
        let deadline = ContinuousClock.now + .seconds(20)
        while history.entries.contains(where: { $0.url == page }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!history.entries.contains { $0.url == page }, "the profile's three-day-old visit is still there")
        #expect(keptHistory.entries.contains { $0.url == page }, "another profile's history was cleared too")
    }
}

/// Toggle Omnibar runs on the focused browser tab instead of showing a
/// greyed-out reason, and says why with no browser tab to act on.
@MainActor @Suite(.serialized)
struct ToggleOmnibarActionTests {
    @Test func toggleOmnibarIsAvailableAndNeedsABrowserTab() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: "palette.browserToggleOmnibar") == nil,
                "Toggle Omnibar is still greyed out")
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform("palette.browserToggleOmnibar", invocation: ActionInvocation())
        }
        #expect(refusal != nil, "a run with no browser tab did nothing silently")
    }
}
