import Foundation
@testable import CmuxNextApp
@testable import CmuxNextHome
import Testing

/// p10-stability-191: the app's and Home's text passes keep their results on the bounded patterns
/// and scans: a terminal preview's lines and the SVG label flattener.
@Suite struct RegexInputBoundsTests {
    @Test func screenLinesDropTrailingWhiteSpaceAndBlankLines() {
        let screen = "a  \n\n  b\t \n" + String(repeating: " ", count: 4000) + "\nc d \u{3000}\n   "
        #expect(HomeLinkPreviewProvider.lastScreenLines(screen) == ["a", "  b", "c d"])
        let many = (1...10).map { "line \($0)  " }.joined(separator: "\n")
        #expect(HomeLinkPreviewProvider.lastScreenLines(many) == (5...10).map { "line \($0)" })
    }

    @Test func aLabelWithAnOpenTagStaysAsWritten() {
        let svg = "<svg>" + String(repeating: "<text a=\"1\" ", count: 3000) + "</svg>"
        #expect(SVGTextFlattener().flatten(svg + "<tspan") == svg + "<tspan")
        // A good label after the damaged ones is still flattened.
        let good = #"<text class="l"><tspan x="0" y="1">A</tspan><tspan x="0" y="9">B</tspan></text>"#
        let flat = SVGTextFlattener().flatten(svg + good)
        #expect(flat.hasSuffix(#"<text class="l" x="0" y="1">A</text><text class="l" x="0" y="9">B</text>"#))
    }
}

/// The time each pass takes on 64 KiB built to make it rescan: under 50 ms (the former patterns
/// took seconds). Timing is not a CI check (Lawrence 2026-10-23): it runs with
/// `CMUX_REGEX_BUDGET_FUZZ=1`, which agents set on the fleet.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_REGEX_BUDGET_FUZZ"] == "1",
                "set CMUX_REGEX_BUDGET_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"))
struct RegexInputBudgetTests {
    static func within50ms(_ what: String, _ body: () -> Void) {
        let took = ContinuousClock().measure(body)
        #expect(took < .milliseconds(50), "\(what) took \(took)")
    }

    @Test func screenLinesAreLinear() {
        let screen = String(repeating: " ", count: 64 << 10) + "x"
        Self.within50ms("lastScreenLines of a wide blank run") { _ = HomeLinkPreviewProvider.lastScreenLines(screen) }
    }

    @Test func theFlattenerIsLinear() {
        for piece in ["<text ", "<text><tspan ", "<text><tspan x=\"0\" y=\"0\">a</tspan>"] {
            let svg = String(repeating: piece, count: (64 << 10) / piece.utf8.count)
            Self.within50ms("SVGTextFlattener.flatten of \(piece.debugDescription) repeated") { _ = SVGTextFlattener().flatten(svg) }
        }
    }
}
