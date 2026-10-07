@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The icon picker host (R94): the session the page opens with, how a finish
/// is accepted, the prefs merge, and which symbol image requests are served.
@MainActor
struct IconPickerHostTests {
    @Test func sessionOpensOnTheCurrentIconsKind() {
        let none = IconPickerSession(id: "s", current: nil)
        #expect(none.tab == "emoji" && !none.canClear)
        let symbol = IconPickerSession(id: "s", current: "star.fill")
        #expect(symbol.tab == "symbol" && symbol.canClear)
        #expect(symbol.event["value"] == .string("star.fill"))
        #expect(IconPickerSession(id: "s", current: "🚀").tab == "emoji")
        // A stored value the rule does not accept offers no Remove (nothing valid to remove).
        #expect(!IconPickerSession(id: "s", current: "not an icon").canClear)
    }

    @Test func finishAppliesOnlyToItsSessionAndOnlyValidIcons() {
        let ok: JSONValue = .object(["session": .string("s1"), "value": .string("🎉")])
        #expect(IconPickerResult.decode(ok, session: "s1") == .set("🎉"))
        #expect(IconPickerResult.decode(ok, session: "s2") == nil)
        #expect(IconPickerResult.decode(.object(["session": .string("s1"), "value": .string("a b")]), session: "s1") == nil)
        #expect(IconPickerResult.decode(.object(["session": .string("s1"), "clear": .bool(true)]), session: "s1") == .clear)
        #expect(IconPickerResult.decode(.object(["session": .string("s1"), "cancel": .bool(true)]), session: "s1") == .cancel)
        #expect(IconPickerResult.decode(.object(["session": .string("s1")]), session: "s1") == nil)
    }

    @Test func aSessionFinishesOnce() async throws {
        var results: [IconPickerResult] = []
        let provider = IconPickerProvider(session: IconPickerSession(id: "s1", current: nil),
                                          prefs: IconPickerPrefsStore(services: nil)) { results.append($0) }
        let context = PageCallContext(page: "cmux.icon-picker")
        _ = try await provider.call("cmux.iconPicker.finish", params: .object(["session": .string("s1"), "value": .string("🚀")]),
                                    context: context)
        provider.finish(.cancel)
        #expect(results == [.set("🚀")])
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.iconPicker.asset.put", params: .object([:]), context: context)
        }
    }

    @Test func prefsMergeKeepsEveryRecentAndOurTone() {
        func entry(_ key: String, _ count: Double, _ last: Double) -> JSONValue {
            .object(["key": .string(key), "count": .number(count), "last": .number(last)])
        }
        let theirs: JSONValue = .object(["tone": JSONValue(2), "recents": .array([entry("emoji:🐱", 5, 10), entry("emoji:🚀", 1, 30)])])
        let ours: JSONValue = .object(["tone": JSONValue(4), "recents": .array([entry("emoji:🐱", 2, 40)])])
        let merged = IconPickerPrefs.merge(theirs, ours)
        #expect(merged["tone"] == JSONValue(4))
        #expect(merged["recents"] == .array([entry("emoji:🐱", 5, 40), entry("emoji:🚀", 1, 30)]))
    }

    @Test func symbolRequestsNameOneValidSymbol() {
        func request(_ path: [String]) -> PageResourceRequest {
            PageResourceRequest(prefix: IconPickerSymbols.prefix, path: path, url: URL(string: "cmux-page://cmux.icon-picker/x")!)
        }
        #expect(IconPickerSymbols.name(for: request(["star.fill.png"])) == "star.fill")
        #expect(IconPickerSymbols.name(for: request(["Star.png"])) == nil)
        #expect(IconPickerSymbols.name(for: request(["a", "b.png"])) == nil)
        #expect(IconPickerSymbols.name(for: request(["star.fill"])) == nil)
        #expect(IconPickerSymbols.png("star.fill") != nil)
        #expect(IconPickerSymbols.png("no.such.symbol.zz") == nil)
    }
}
