@testable import CmuxNextDaemon
import Foundation
import Testing

/// A terminal record's `extra.prompt.since_ms` (a shell at its prompt, OSC 133 A..C) and
/// `extra.last_output.at_ms` (when it last printed) reach the mirror from a delta upsert, and a
/// newer output time is a change the store lays over the tab again.
@Suite struct TerminalPromptOutputDecodeTests {
    private func delta(_ extra: String) throws -> [SessionStateChange] {
        let line = #"{"type":"stream_item","item":{"kind":"delta","changes":[{"kind":"upsert","resource":"terminal","id":"term_7","value":{"id":"term_7","extra":\#(extra)}}]}}"#
        guard case .delta(let changes)? = SessionStreamItem.decode(Data(line.utf8)) else {
            Issue.record("not a delta")
            return []
        }
        return changes
    }

    @Test func aTerminalUpsertCarriesItsPromptAndLastOutput() throws {
        let changes = try delta(#"{"prompt":{"since_ms":"1700000000000"},"last_output":{"at_ms":"1700000012000"}}"#)
        #expect(changes == [.terminal("term_7", nil, promptSinceMs: 1_700_000_000_000, lastOutputMs: 1_700_000_012_000)])
        var mirror = SessionStateMirror()
        var touched: Set<SessionStateMirror.Touched> = []
        mirror.apply(changes[0], touched: &touched)
        #expect(mirror.terminalPromptSinceMs["term_7"] == 1_700_000_000_000)
        #expect(mirror.terminalLastOutputMs["term_7"] == 1_700_000_012_000)
        #expect(touched == [.terminal("term_7")])

        touched = []
        mirror.apply(try delta(#"{"prompt":{"since_ms":"1700000000000"},"last_output":{"at_ms":"1700000017000"}}"#)[0], touched: &touched)
        #expect(mirror.terminalLastOutputMs["term_7"] == 1_700_000_017_000)
        #expect(touched == [.terminal("term_7")], "newer output is a change")
    }

    /// A record that drops the prompt and the last output (nothing else changed): the mirror clears
    /// both, and that alone is a change, so no stale prompt or output time survives.
    @Test func aTerminalWithoutThemHasNeither() throws {
        var mirror = SessionStateMirror()
        mirror.apply(try delta(#"{"prompt":{"since_ms":"1700000000000"},"last_output":{"at_ms":"1700000012000"}}"#)[0])
        #expect(mirror.terminalLastOutputMs["term_7"] == 1_700_000_012_000)

        let changes = try delta("{}")
        #expect(changes == [.terminal("term_7", nil)])
        var touched: Set<SessionStateMirror.Touched> = []
        mirror.apply(changes[0], touched: &touched)
        #expect(mirror.terminalPromptSinceMs["term_7"] == nil)
        #expect(mirror.terminalLastOutputMs["term_7"] == nil)
        #expect(touched == [.terminal("term_7")], "dropping them is a change")
    }
}
