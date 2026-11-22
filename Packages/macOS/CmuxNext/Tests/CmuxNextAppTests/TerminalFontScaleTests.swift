@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTerminal
import Foundation
import Testing

/// A terminal's font zoom is saved on its tab record as a scale of the
/// configured font size, and only when it changed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct TerminalFontScaleTests {
    @Test func fontScaleIsRelativeToTheConfiguredSize() {
        #expect(TerminalFontScale.scale(points: 15, adjusted: true, base: 12) == 1.25)
        #expect(TerminalFontScale.scale(points: 12, adjusted: true, base: 12) == nil)
        #expect(TerminalFontScale.scale(points: 15, adjusted: false, base: 12) == nil)
        #expect(TerminalFontScale.scale(points: 15, adjusted: true, base: nil) == nil)
    }

    @Test func aChangedScaleIsSavedOnTheTabRecord() async throws {
        let entities = #""tabs":[{"id":"tab_a","pane_id":"pane_p","name":null,"index":0,"focused":true,"content_kind":"terminal","content_id":"term_a","extra":{"zoom":1.5}}]"#
        let daemon = try StateDaemon(state: "{}", entities: entities)
        defer { daemon.stop() }
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.start(makeConnection: { daemon.connection() })
        defer { services.daemon.shutdownConnection() }
        let clock = ContinuousClock(), end = clock.now.advanced(by: .seconds(10))
        while !(services.daemon.store.isLoaded && services.daemon.store.servesStateResources && services.daemon.store.session.known), clock.now < end {
            try await clock.sleep(for: .milliseconds(20)) // test-only wait
        }
        let key = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first?.id)
        #expect(services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first?.zoom == 1.5)

        // Unchanged: nothing is sent.
        TabContentCache.saveFontScale(1.5, tab: key, daemon: services.daemon)
        TabContentCache.saveFontScale(2, tab: key, daemon: services.daemon)
        while !daemon.operations.contains("tab.update"), clock.now < end { try await clock.sleep(for: .milliseconds(20)) }
        #expect(daemon.operations.filter { $0 == "tab.update" }.count == 1)
        let params = try #require(daemon.params(of: "tab.update"))
        #expect(params["tab"] == .string("tab_a") && params["zoom"] == .number(2))
    }
}
