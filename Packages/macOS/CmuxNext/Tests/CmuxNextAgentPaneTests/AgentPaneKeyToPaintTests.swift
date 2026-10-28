import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Testing

/// `pane.keyToPaint`: the page probe's histogram (webviews/src/ui/frameInput.ts) decodes to numbers
/// only, and a report that breaks the shape is refused.
struct AgentPaneKeyToPaintTests {
    /// A report as the page posts it, through the page host's JSON (``JSONValue/foundationObject``).
    private static func body(_ members: [String: JSONValue]) -> Any {
        JSONValue.object(["method": .string("pane.keyToPaint"), "params": .object(members)]).foundationObject
    }

    private static let report: [String: JSONValue] = [
        "kind": .string("key_to_paint"),
        "bounds_ms": .array([.number(8), .number(16), .number(33)]),
        "counts": .array([.number(2), .number(1), .number(0), .number(1)]),
        "count": .number(4),
        "sum_ms": .number(61.5),
        "max_ms": .number(40.25),
        "window_ms": .number(10_012),
    ]

    @Test func thePagesReportDecodes() throws {
        let request = AgentPaneRequest(body: Self.body(Self.report))
        guard case .keyToPaint(let report) = request else {
            Issue.record("expected keyToPaint, got \(request)")
            return
        }
        #expect(report.boundsMilliseconds == [8, 16, 33])
        #expect(report.counts == [2, 1, 0, 1])
        #expect(report.count == 4)
        #expect(report.sumMilliseconds == 61.5)
        #expect(report.maxMilliseconds == 40.25)
        #expect(report.windowMilliseconds == 10_012)
        // The log name carries no numbers.
        #expect(String(describing: request) == "keyToPaint")
    }

    @Test(arguments: [
        ("counts that do not add up", "count", JSONValue.number(5)),
        ("one bucket short", "counts", JSONValue.array([.number(2), .number(1), .number(1)])),
        ("a fractional count", "counts", JSONValue.array([.number(1.5), .number(1), .number(0), .number(1.5)])),
        ("bounds out of order", "bounds_ms", JSONValue.array([.number(16), .number(8), .number(33)])),
        ("a negative time", "max_ms", JSONValue.number(-1)),
        ("text for a number", "sum_ms", JSONValue.string("61.5")),
        ("a boolean for a number", "window_ms", JSONValue.bool(true)),
    ])
    func aBrokenReportIsRefused(_ label: String, key: String, value: JSONValue) {
        var members = Self.report
        members[key] = value
        #expect(AgentPaneRequest(body: Self.body(members)) == .unsupported("pane.keyToPaint"), "\(label)")
    }

    @Test func thePageMayCallIt() {
        #expect(AgentPageOps.all.contains("cmux.agent.pane.keyToPaint"))
    }
}
