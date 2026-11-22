import AppKit
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

    /// Copy in the picker's Actions menu writes the pasteboard; the page runs no app action.
    @Test func thePickerPageMayWriteTheClipboardAndNothingElseOfTheApp() {
        #expect(PageDescriptor.iconPicker.admits(PageNativeOp.clipboardWrite))
        #expect(!PageDescriptor.iconPicker.admits(PageNativeOp.actionRun))
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
        let provider = IconPickerProvider(prefs: IconPickerPrefsStore(services: nil))
        provider.begin(IconPickerSession(id: "s1", current: nil)) { results.append($0) }
        let context = PageCallContext(page: "cmux.icon-picker")
        _ = try await provider.call("cmux.iconPicker.finish", params: .object(["session": .string("s1"), "value": .string("🚀")]),
                                    context: context)
        provider.finish(.cancel)
        #expect(results == [.set("🚀")])
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.iconPicker.asset.put", params: .object([:]), context: context)
        }
    }

    /// S3 d: the warm page's one provider serves every session over one subscription. The
    /// catalog goes with the first event of a page load; a later session's event has none; a
    /// late finish from an earlier session is refused.
    @Test func oneProviderServesEverySessionOfTheWarmPage() async throws {
        let catalog = IconPickerSymbolCatalog(names: ["star"], keywords: [""], categories: [])
        let provider = IconPickerProvider(prefs: IconPickerPrefsStore(services: nil), catalog: catalog, maxEmojiVersion: 160)
        let context = PageCallContext(page: "cmux.icon-picker")
        var events: [JSONValue] = []
        var results: [String] = []
        provider.begin(IconPickerSession(id: "s1", current: nil)) { results.append("s1 \($0)") }
        _ = try await provider.subscribe(IconPickerProvider.sessionStream, filter: .null, context: context) { events.append($0) }
        #expect(events.map { $0["id"] } == [.string("s1")])
        #expect(events.first?["symbols"] == .array([.string("star")]))
        #expect(events.first?["maxEmojiVersion"] == JSONValue(160))

        provider.finish(.cancel)
        provider.begin(IconPickerSession(id: "s2", current: "🚀")) { results.append("s2 \($0)") }
        #expect(events.map { $0["id"] } == [.string("s1"), .string("s2")])
        #expect(events.last?["symbols"] == nil && events.last?["value"] == .string("🚀"))
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.iconPicker.finish", params: .object(["session": .string("s1"), "value": .string("🎉")]),
                                    context: context)
        }
        _ = try await provider.call("cmux.iconPicker.finish", params: .object(["session": .string("s2"), "value": .string("🎉")]),
                                    context: context)
        #expect(results == ["s1 cancel", "s2 set(\"🎉\")"])

        // A page reload (a crash) subscribes again and gets the catalog with the current session.
        var reloaded: [JSONValue] = []
        _ = try await provider.subscribe(IconPickerProvider.sessionStream, filter: .null, context: context) { reloaded.append($0) }
        #expect(reloaded.first?["id"] == .string("s2") && reloaded.first?["symbols"] != nil)
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

    @Test func symbolRequestsNameOneValidSymbolAndMode() {
        func request(_ path: [String]) -> PageResourceRequest {
            PageResourceRequest(prefix: IconPickerSymbols.prefix, path: path, url: URL(string: "cmux-page://cmux.icon-picker/x")!)
        }
        func parsed(_ path: [String]) -> String? {
            IconPickerSymbols.symbol(for: request(path)).map { "\($0.mode.rawValue):\($0.name)" }
        }
        #expect(parsed(["star.fill.png"]) == "monochrome:star.fill")
        #expect(parsed(["hierarchical", "star.fill.png"]) == "hierarchical:star.fill")
        #expect(parsed(["multicolor", "cloud.sun.fill.png"]) == "multicolor:cloud.sun.fill")
        #expect(parsed(["sepia", "star.png"]) == nil)
        #expect(parsed(["Star.png"]) == nil)
        #expect(parsed(["a", "b", "c.png"]) == nil)
        #expect(parsed(["star.fill"]) == nil)
        #expect(IconPickerSymbols.png("star.fill") != nil)
        #expect(IconPickerSymbols.png("no.such.symbol.zz") == nil)
    }

    /// Opaque pixels of a PNG: whether each has a hue (not gray) and whether it is red.
    static func pixels(_ png: Data) -> [(colored: Bool, red: Bool, light: Bool)] {
        guard let bitmap = NSBitmapImageRep(data: png) else { return [] }
        var out: [(colored: Bool, red: Bool, light: Bool)] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
                let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
                out.append((max(r, g, b) - min(r, g, b) > 0.15, r > 0.6 && g < 0.45 && b < 0.45, max(r, g, b) > 0.2))
            }
        }
        return out
    }

    /// Monochrome and hierarchical are black templates the page tints with its theme's foreground
    /// (Ghostty colors, never the system accent); multicolor has the symbol's own colors (the
    /// yellow sun of cloud.sun.fill).
    @Test func renderingModesDrawColorWhereTheModeHasIt() throws {
        let mono = Self.pixels(try #require(IconPickerSymbols.png("cloud.sun.fill")))
        let multi = Self.pixels(try #require(IconPickerSymbols.png("cloud.sun.fill", mode: .multicolor)))
        let hierarchical = Self.pixels(try #require(IconPickerSymbols.png("cloud.sun.fill", mode: .hierarchical)))
        #expect(!mono.isEmpty && !mono.contains { $0.colored })
        #expect(multi.contains { $0.colored })
        #expect(!hierarchical.isEmpty && !hierarchical.contains { $0.colored || $0.light })
    }

    /// The drawn images' cache key goes with every session and changes with the appearance.
    @Test func everySessionCarriesTheSymbolStyle() {
        var session = IconPickerSession(id: "s", current: nil)
        session.symbolStyle = IconPickerSymbols.style(dark: true)
        #expect(session.event["symbolStyle"] == .string("dark"))
        #expect(IconPickerSymbols.style(dark: false) == "light")
    }

    /// The rendering mode is a pref: ours wins, theirs is kept when we have none.
    @Test func prefsMergeKeepsTheSymbolMode() {
        let multicolor: JSONValue = .object(["symbolMode": .string("multicolor")])
        let hierarchical: JSONValue = .object(["symbolMode": .string("hierarchical")])
        #expect(IconPickerPrefs.merge(multicolor, hierarchical)["symbolMode"] == .string("hierarchical"))
        #expect(IconPickerPrefs.merge(multicolor, .object([:]))["symbolMode"] == .string("multicolor"))
        #expect(IconPickerPrefs.merge(.null, .null)["symbolMode"] == nil)
    }
}
