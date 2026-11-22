@testable import CmuxNextApp
import CmuxNextSettings
import CmuxNextTerminal
import Foundation
import Testing

/// The diagnostics model reads the applied config at start and again on
/// every Ghostty config change; the Settings page's host lists carry it.
@MainActor
struct GhosttyDiagnosticsModelTests {
    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
    }

    @Test func theModelFollowsEveryConfigChange() async {
        let center = NotificationCenter()
        var current = [GhosttyConfigDiagnostic(kind: .key, name: "window-decoration", file: "/c", line: 1,
                                               support: GhosttyUnsupported(.superseded, replacement: "window.titlebar"))]
        let model = GhosttyDiagnosticsModel(read: { GhosttyConfigDiagnosticsSnapshot(diagnostics: current) }, notifications: center)
        await Self.settle { model.diagnostics != nil }
        #expect(model.diagnostics?.map(\.name) == ["window-decoration"])
        current = []
        center.post(name: GhosttyRuntime.configDidChange, object: nil)
        await Self.settle { model.diagnostics?.isEmpty == true }
        #expect(model.diagnostics == [], "a reload that fixed the file empties the list")
    }

    @Test func theSettingsHostListsCarryTheDiagnostics() async {
        let services = ActionBindingCoverageTests.boundServices()
        await Self.settle { GhosttyDiagnosticsModel.shared.diagnostics != nil }
        let lists = services.settingsWindow.pageHostLists()
        let expected = GhosttyDiagnosticsModel.shared.diagnostics.map { JSONValue.array($0.map(GhosttyDiagnosticsControl.json)) }
        #expect(expected != nil)
        #expect(lists.objectValue?["ghostty_diagnostics"] == expected)
    }
}
