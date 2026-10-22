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
            // The text system's own line breaker: the last place a line can break before the name's
            // end is where the name starts (the space before it), never inside it. With no break in
            // the range it answers the range's start, so the range starts at the line's start.
            let breakAt = shown.lineBreak(before: NSMaxRange(range), within: NSRange(location: 0, length: NSMaxRange(range)))
            #expect(breakAt <= range.location, "\(text) breaks at \(breakAt), inside \(name) at \(range.location)")
            // And a line still breaks between words: at the space just before the name.
            #expect(breakAt > 0 && breakAt == range.location, "\(text) has no break before \(name)")
        }
    }

    /// The names read as typed: only their hyphens change, to the non-breaking hyphen that draws the same.
    @Test func theNamesReadAsTyped() throws {
        let turn = try #require(HomeEngineTurn(line: Self.line))
        #expect(HomeEngineStrings.engineTitle(turn).replacingOccurrences(of: "\u{2011}", with: "-") == "claude-sr2-pipe, claude-opus-5-5")
    }
}
