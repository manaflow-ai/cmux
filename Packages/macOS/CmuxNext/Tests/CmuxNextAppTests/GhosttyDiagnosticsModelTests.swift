@testable import CmuxNextApp
import CmuxNextSettings
import CmuxNextTerminal
import Foundation
import Testing

/// The diagnostics model reads the applied config at start and again on
/// every Ghostty config change; the Settings page's host lists carry it.
@MainActor
struct GhosttyDiagnosticsModelTests {
    @Test func theModelFollowsEveryConfigChange() {
        let center = NotificationCenter()
        var current = [GhosttyConfigDiagnostic(kind: .key, name: "window-decoration", file: "/c", line: 1,
                                               support: GhosttyUnsupported(.superseded, replacement: "window.titlebar"))]
        let model = GhosttyDiagnosticsModel(read: { (current, ["/c"]) }, notifications: center)
        #expect(model.diagnostics.map(\.name) == ["window-decoration"])
        #expect(model.files == ["/c"])
        current = []
        center.post(name: GhosttyRuntime.configDidChange, object: nil)
        #expect(model.diagnostics.isEmpty, "a reload that fixed the file empties the list")
    }

    @Test func theSettingsHostListsCarryTheDiagnostics() {
        let services = ActionBindingCoverageTests.boundServices()
        let lists = services.settingsWindow.pageHostLists()
        let expected = JSONValue.array(GhosttyDiagnosticsModel.shared.diagnostics.map(GhosttyDiagnosticsControl.json))
        #expect(lists.objectValue?["ghostty_diagnostics"] == expected)
    }
}
