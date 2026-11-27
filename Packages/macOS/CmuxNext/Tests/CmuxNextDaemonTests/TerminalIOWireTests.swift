import Foundation
import Testing
@testable import CmuxNextDaemon

/// Golden wire bytes of the TerminalIO requests generated from the schema (bindings.json): the
/// field names, which fields are always encoded, and which are omitted when unset.
struct TerminalIOWireTests {
    private func wire<R: DaemonRequest>(_ request: R) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: 7))
    }

    @Test func terminalFindEncodesTheThreeFlagsAlwaysAndPagingOnlyWhenSet() throws {
        let plain = try wire(TerminalFindRequest(surface: 12, query: "needle"))
        #expect(plain == .object(["cmd": .string("terminal-find"), "id": .number(7), "surface": .number(12),
                                  "query": .string("needle"), "case_sensitive": .bool(false),
                                  "whole_word": .bool(false), "regex": .bool(false)]))
        let paged = try wire(TerminalFindRequest(surface: 12, query: "n.+e", caseSensitive: true, wholeWord: true,
                                                 regex: true, before: 40, epoch: 3))
        #expect(paged == .object(["cmd": .string("terminal-find"), "id": .number(7), "surface": .number(12),
                                  "query": .string("n.+e"), "case_sensitive": .bool(true), "whole_word": .bool(true),
                                  "regex": .bool(true), "before": .number(40), "epoch": .number(3)]))
    }

    @Test func offerLinkToPhoneEncodesTheTerminalAndUrl() throws {
        let value = try wire(OfferLinkToPhoneRequest(terminalID: "terminal_a", url: "https://example.com/x"))
        #expect(value == .object(["cmd": .string("offer-link-to-phone"), "id": .number(7),
                                  "terminal_id": .string("terminal_a"), "url": .string("https://example.com/x")]))
    }

    @Test func terminalFindDecodesAPageAndNamesTheMatchedText() throws {
        let line = #"{"ok":true,"data":{"matches":[{"start":{"marker":9,"column":2},"end":{"marker":9,"column":5},"rows_from_bottom":4,"snippet":"a needle b","snippet_start":2,"snippet_len":6}],"next_before":9,"complete":false,"epoch":3,"cols":80}}"#
        let page = try WireCoding.decodeResponse(TerminalFindRequest.Response.self, from: Data(line.utf8))
        #expect(page.matches.first?.text == "needle")
        #expect(page.nextBefore == 9)
        #expect(page.epoch == 3)
        #expect(page.restarted == nil)
    }
}
