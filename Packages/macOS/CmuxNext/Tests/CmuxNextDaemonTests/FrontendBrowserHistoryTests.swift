import Foundation
import Testing
@testable import CmuxNextDaemon

/// `frontend-browser-history-v1` wire shapes and the per-tab bound.
@Suite struct FrontendBrowserHistoryTests {
    private func object<R: DaemonRequest>(_ request: R) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    private static func history(_ count: Int, index: Int) -> FrontendBrowserHistory {
        FrontendBrowserHistory(entries: (0..<count).map { .init(url: "https://e\($0).test/") }, index: index)
    }

    @Test func setSendsTheHistoryObjectAndNullClearsIt() throws {
        let entry = FrontendBrowserHistory.Entry(url: "https://a.test/", title: "A", scrollY: 640)
        let set = try object(SetFrontendBrowserHistoryRequest(surface: 5, history: FrontendBrowserHistory(entries: [entry], index: 0)))
        #expect(set["cmd"] == .string("set-frontend-browser-history"))
        #expect(set["surface"] == .number(5))
        #expect(set["history"]?["index"] == .number(0))
        guard case .array(let entries)? = set["history"]?["entries"] else { Issue.record("no entries"); return }
        #expect(entries.first?["scroll_y"] == .number(640))
        #expect(entries.first?["url"] == .string("https://a.test/"))

        let clear = try object(SetFrontendBrowserHistoryRequest(surface: 5, history: nil))
        #expect(clear["history"] == .null)
    }

    @Test func getDecodesTheStoredHistoryOrNone() throws {
        let get = try object(GetFrontendBrowserHistoryRequest(surface: 9))
        #expect(get["cmd"] == .string("get-frontend-browser-history"))
        let stored = #"{"ok":true,"data":{"surface":9,"history":{"entries":[{"url":"https://a.test/","title":"A","scroll_y":12.5},{"url":"https://b.test/"}],"index":1}}}"#
        let reply = try WireCoding.decodeResponse(GetFrontendBrowserHistoryRequest.Response.self, from: Data(stored.utf8))
        #expect(reply.history == FrontendBrowserHistory(entries: [.init(url: "https://a.test/", title: "A", scrollY: 12.5),
                                                                  .init(url: "https://b.test/")], index: 1))
        let none = #"{"ok":true,"data":{"surface":9,"history":null}}"#
        #expect(try WireCoding.decodeResponse(GetFrontendBrowserHistoryRequest.Response.self, from: Data(none.utf8)).history == nil)
        let set = #"{"ok":true,"data":{"surface":9}}"#
        _ = try WireCoding.decodeResponse(SetFrontendBrowserHistoryRequest.Response.self, from: Data(set.utf8))
    }

    /// The bound keeps the current entry and those nearest it.
    @Test func boundedKeepsTheEntriesNearestTheCurrentOne() throws {
        let short = Self.history(3, index: 1)
        #expect(short.bounded(maxEntries: 5) == short)

        let middle = try #require(Self.history(40, index: 20).bounded(maxEntries: 5))
        #expect(middle.entries.map(\.url) == (16...20).map { "https://e\($0).test/" })
        #expect(middle.index == 4)

        let start = try #require(Self.history(40, index: 2).bounded(maxEntries: 5))
        #expect(start.entries.map(\.url) == (0...4).map { "https://e\($0).test/" })
        #expect(start.index == 2)

        let end = try #require(Self.history(40, index: 39).bounded(maxEntries: 5))
        #expect(end.entries.first?.url == "https://e35.test/")
        #expect(end.index == 4)

        #expect(Self.history(3, index: 3).bounded() == nil)
    }
}
