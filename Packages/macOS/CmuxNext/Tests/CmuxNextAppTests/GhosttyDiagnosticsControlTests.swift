@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import CmuxNextTerminal
import Testing

/// `ghostty.diagnostics` on the app socket reports each finding of the R92
/// diagnostics model with its file, line, reason and replacement.
@MainActor
struct GhosttyDiagnosticsControlTests {
    @Test func theSocketReportsEachFindingWithItsSourceAndReason() async throws {
        let snapshot = GhosttyConfigDiagnosticsSnapshot(diagnostics: [
            GhosttyConfigDiagnostic(kind: .key, name: "window-decoration", file: "/u/.config/ghostty/config", line: 2,
                                    support: GhosttyUnsupported(.superseded, replacement: "window.titlebar")),
            GhosttyConfigDiagnostic(kind: .invalid, name: "/u/.config/ghostty/config:5:bogus: unknown field"),
        ], files: ["/nonexistent-ghostty-diagnostics-test/config"])
        let control = GhosttyDiagnosticsControl(snapshot: { snapshot })
        let router = ControlRouter(identity: ControlIdentity(version: "1", build: "1", bundleID: nil, tag: "test", processID: 1),
                                   executor: RegistryControlBridge(registry: ActionRegistry()))
        router.register([control.method])
        let result = await router.handle(ControlRequest(id: "1", method: "ghostty.diagnostics", params: [:]))
        let report = try result.get().objectValue
        #expect(report?["files"] == .array([.string("/nonexistent-ghostty-diagnostics-test/config")]))
        let items = try #require(report?["diagnostics"]?.arrayValue)
        #expect(items.count == 2)
        #expect(items[0] == .object([
            "kind": .string("key"), "name": .string("window-decoration"), "file": .string("/u/.config/ghostty/config"),
            "line": .number(2), "reason": .string("superseded"), "replacement": .string("window.titlebar"),
        ]))
        #expect(items[1].objectValue?["kind"] == .string("invalid"))
        #expect(items[1].objectValue?["reason"] == .null)
    }
}
