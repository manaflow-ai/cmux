import AppKit
import CmuxNextDesign
@testable import CmuxNextHomeEngine
import Testing

/// Leo's screenshot of the Chief Settings card (2026-10-20): Diagnostics wrapped inside an engine's
/// name, "claude-sr2-" at the end of one line and "pipe" on the next. A harness or model name in the
/// diagnostics never breaks across lines; the lines still break at the spaces between words.
@MainActor @Suite struct HomeChiefDiagnosticsWrapTests {
    static let line = #"{"ev":"turn.end","harness":"claude-sr2-pipe","model":"claude-opus-5-5","ms":3600,"reply":{"prefix":"I'll stop killing git processes"}}"#

    @Test(arguments: [false, true])
    func anEngineNameNeverBreaksAcrossLines(lastTurn: Bool) throws {
        let turn = try #require(HomeEngineTurn(line: Self.line))
        let text = lastTurn ? HomeEngineStrings.lastTurn(turn) : HomeEngineStrings.reply(turn)
        let shown = NSAttributedString(string: text, attributes: [.font: Typography.caption])
        for name in ["claude-sr2-pipe", "claude-opus-5-5"] {
            let drawn = name.replacingOccurrences(of: "-", with: "\u{2011}")
            let range = (text as NSString).range(of: drawn)
            #expect(range.location != NSNotFound, "\(name) is not in \(text)")
            // The text system's own line breaker finds no place to break inside the name.
            let inside = NSRange(location: range.location + 1, length: range.length - 1)
            #expect(shown.lineBreak(before: NSMaxRange(range), within: inside) == NSNotFound, "\(text) can break inside \(name)")
        }
        // Between the words a line still breaks.
        #expect(shown.lineBreak(before: shown.length, within: NSRange(location: 1, length: shown.length - 1)) != NSNotFound)
    }

    /// The names read as typed: only their hyphens change, to the non-breaking hyphen that draws the same.
    @Test func theNamesReadAsTyped() throws {
        let turn = try #require(HomeEngineTurn(line: Self.line))
        #expect(HomeEngineStrings.engineTitle(turn).replacingOccurrences(of: "\u{2011}", with: "-") == "claude-sr2-pipe, claude-opus-5-5")
    }
}
