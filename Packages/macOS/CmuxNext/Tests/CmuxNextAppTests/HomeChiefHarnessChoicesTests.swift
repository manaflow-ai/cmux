import Foundation
import Testing
@testable import CmuxNextApp

/// cx-0uq7: the Chief's harness picker offers the user's own Claude login and
/// Codex. The CodeRouter route (`claude-cr`) shows only when this Chief's
/// acpmux has one configured; the subrouter pool is never a default item.
@Suite struct HomeChiefHarnessChoicesTests {
    @Test func withoutARouteThePickerOffersTheUsersOwnLoginAndNoSubrouter() {
        let items = HomeChiefSidebar.harnesses(routeConfigured: false)
        #expect(items == ["claude", "codex"])
        #expect(!items.contains("claude-sr"))
        #expect(!items.contains("claude-cr"))
    }

    @Test func aConfiguredRouteAddsClaudeCr() {
        let items = HomeChiefSidebar.harnesses(routeConfigured: true)
        #expect(items == ["claude", "claude-cr", "codex"])
        #expect(!items.contains("claude-sr"))
    }

    @Test func theRouteIsReadFromTheChiefsAcpmuxConfigOrTheEnvironment() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-route-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let files = HomeChiefFiles(muxHome: home)
        #expect(!files.coderouterRouteConfigured(environment: [:]))
        let config = home.appendingPathComponent("acpmux/config.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"coderouterClaudeRoute": "  "}"#.utf8).write(to: config)
        #expect(!files.coderouterRouteConfigured(environment: [:]))
        try Data(#"{"coderouterClaudeRoute": "team-route"}"#.utf8).write(to: config)
        #expect(files.coderouterRouteConfigured(environment: [:]))
        try FileManager.default.removeItem(at: config)
        #expect(files.coderouterRouteConfigured(environment: ["ACPMUX_CODEROUTER_CLAUDE_ROUTE": "team-route"]))
        #expect(!files.coderouterRouteConfigured(environment: ["ACPMUX_CODEROUTER_CLAUDE_ROUTE": ""]))
    }
}
