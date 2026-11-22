@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// The builder's "Terminal lost" proof kills the exact host behind a tab:
/// `debug.surfaces` names each terminal pane's `terminal_id` and `host_pid`.
@MainActor struct SurfaceHostReportTests {
    private static let report: JSONValue = [
        "windows": .array([
            ["window": "1", "panes": .array([
                ["pane": "p-term", "kind": "terminal"],
                ["pane": "p-page", "kind": "page"],
                ["pane": "p-inproc", "kind": "terminal"],
            ])],
        ]),
        "blank_panes": .number(0),
    ]

    private static func panes(_ report: JSONValue) -> [String: [String: JSONValue]] {
        guard case .object(let root) = report, case .array(let windows)? = root["windows"] else { return [:] }
        var result: [String: [String: JSONValue]] = [:]
        for case .object(let window) in windows {
            guard case .array(let panes)? = window["panes"] else { continue }
            for case .object(let pane) in panes { if case .string(let key)? = pane["pane"] { result[key] = pane } }
        }
        return result
    }

    @Test func terminalPanesGetTheirTerminalIDAndHostPID() {
        let annotated = SurfaceHostReport.annotate(Self.report, identities: [
            "p-term": .init(terminalID: "term_abc", hostPID: 4242),
            "p-inproc": .init(terminalID: "term_def", hostPID: nil),
        ])
        let panes = Self.panes(annotated)
        #expect(panes["p-term"]?["terminal_id"] == .string("term_abc"))
        #expect(panes["p-term"]?["host_pid"] == .number(4242))
        #expect(panes["p-inproc"]?["terminal_id"] == .string("term_def"))
        #expect(panes["p-inproc"]?["host_pid"] == .null, "a PTY with no separate host reports null, not a missing key")
        #expect(panes["p-page"]?["terminal_id"] == nil)
        #expect(panes["p-page"]?["host_pid"] == nil)
        guard case .object(let root) = annotated else { Issue.record("not an object"); return }
        #expect(root["blank_panes"] == .number(0), "the rest of the report is unchanged")
    }
}
