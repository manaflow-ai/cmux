import AppKit
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Link hints (`f`, `F`): labels, the keys of a session, and the letters
/// Chromium reports after the page passed them on.
@MainActor
@Suite struct LinkHintTests {
    private final class Recorder: BrowserTabDelegate {
        var keys: [BrowserPageKey] = []
        var escapes = 0
        func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
            switch intent {
            case .unhandledKey(let key): keys.append(key)
            case .unhandledEscape: escapes += 1
            default: break
            }
        }
    }

    private static func target(_ n: Double, href: String? = nil) -> LinkHintTarget {
        LinkHintTarget(x: n, y: n, left: n, top: n, href: href.flatMap(URL.init(string:)))
    }

    // MARK: Labels

    @Test(arguments: [1, 2, 13, 14, 15, 100, 196, 197, 1000])
    func labelsAreDistinctAndPrefixFree(count: Int) {
        let labels = LinkHintSession.labels(count: count)
        #expect(labels.count == count)
        #expect(Set(labels).count == count)
        for a in labels {
            for b in labels where a != b {
                #expect(!b.hasPrefix(a), "\(a) is a prefix of \(b)")
            }
        }
        let lengths = Set(labels.map(\.count))
        #expect(lengths.count <= 2 && (lengths.max() ?? 0) - (lengths.min() ?? 0) <= 1)
        #expect(labels.allSatisfy { $0.allSatisfy { LinkHintSession.alphabet.contains(String($0)) } })
    }

    @Test func fewTargetsGetSingleHomeRowLetters() {
        #expect(LinkHintSession.labels(count: 3).allSatisfy { $0.count == 1 })
        #expect(LinkHintSession.labels(count: 0).isEmpty)
    }

    // MARK: Session keys

    @Test func lettersNarrowUntilALabelIsComplete() throws {
        var session = LinkHintSession(mode: .follow)
        let targets = (0..<20).map { Self.target(Double($0)) }
        #expect(session.show(targets) == .narrow(prefix: ""))
        let hints = try #require(session.hints)
        let long = try #require(hints.first { $0.label.count == 2 })
        let first = String(long.label.prefix(1))
        #expect(session.type(first) == .narrow(prefix: first))
        #expect(session.type(String(long.label.last!)) == .pick(long.target))
    }

    @Test func aLetterNoLabelContinuesWithIsIgnoredAndBackspaceUndoes() throws {
        var session = LinkHintSession(mode: .follow)
        _ = session.show([Self.target(1), Self.target(2)])
        #expect(session.type("z") == .narrow(prefix: ""))
        let label = try #require(session.hints?.first?.label)
        #expect(session.type(nil) == .narrow(prefix: ""))
        #expect(session.type(label.uppercased()) == .pick(Self.target(1)))
    }

    @Test func keysTypedBeforeTheLabelsArriveCount() {
        var session = LinkHintSession(mode: .follow)
        #expect(session.type("a") == .narrow(prefix: "a"))
        #expect(session.type("q") == .narrow(prefix: "aq"))
        // Two targets get `a` and `s`: `q` fits no label and is dropped.
        #expect(session.hints?.map(\.label) == nil)
        #expect(session.show([Self.target(1), Self.target(2)]) == .pick(Self.target(1)))
    }

    @Test func newSplitLabelsLinksOnly() {
        var session = LinkHintSession(mode: .newSplit)
        let link = Self.target(2, href: "https://a.example/")
        #expect(session.show([Self.target(1), link]) == .narrow(prefix: ""))
        #expect(session.hints?.map(\.target) == [link], "only the link is labeled")
        var none = LinkHintSession(mode: .newSplit)
        #expect(none.show([Self.target(1)]) == .cancel)
        var empty = LinkHintSession(mode: .follow)
        #expect(empty.show([]) == .cancel)
    }

    // MARK: Page script results

    @Test func targetsKeepOnlyWebLinks() {
        let json = """
        [{"x":1,"y":2,"left":0,"top":0,"href":"https://a.example/"},
         {"x":3,"y":4,"left":2,"top":2,"href":"javascript:alert(1)"},
         {"x":5,"y":6,"left":4,"top":4,"href":null},
         {"x":7,"y":8,"left":6,"top":6}]
        """
        let targets = LinkHintSession.targets(from: .string(json))
        #expect(targets.map(\.href) == [URL(string: "https://a.example/"), nil, nil, nil])
        #expect(targets.map(\.x) == [1, 3, 5, 7])
        #expect(LinkHintSession.targets(from: .string("nope")).isEmpty)
        #expect(LinkHintSession.targets(from: .bool(true)).isEmpty)
    }

    @Test func aTypedPrefixIsAQuotedLiteral() {
        #expect(LinkHintSession.scriptLiteral("sa") == "\"sa\"")
        #expect(LinkHintSession.scriptLiteral("'); x('") == "\"'); x('\"")
        #expect(LinkHintSession.narrowScript("sa").contains("})(\"sa\")"))
    }

    // MARK: Letters the page passed on

    @Test func pageKeysAreLettersOnly() {
        #expect(BrowserPageKey(windowsKeyCode: 0x46, shift: false) == BrowserPageKey(character: "f", shift: false))
        #expect(BrowserPageKey(windowsKeyCode: 0x46, shift: true) == BrowserPageKey(character: "F", shift: true))
        #expect(BrowserPageKey(windowsKeyCode: 0x41, shift: false)?.character == "a")
        #expect(BrowserPageKey(windowsKeyCode: 0x5A, shift: false)?.character == "z")
        for code in [0x1B, 0x30, 0x40, 0x5B, 0x70] {
            #expect(BrowserPageKey(windowsKeyCode: code, shift: false) == nil)
        }
    }

    @Test func theShimReportsUnhandledLettersAndEscape() {
        let runtime = CEFRuntime.shared
        let host = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        let recorder = Recorder()
        tab.delegate = recorder
        runtime.register(tab, browser: 71_106)
        defer { runtime.tabsByBrowser[71_106] = nil }
        for (code, shift) in [(0x46, 0), (0x46, 1), (0x1B, 0), (0x31, 0)] {
            runtime.handle(CEFShimEvent(kind: 28, browser: 71_106, request: 0, a: Int64(code), b: Int64(shift), s1: "", s2: ""))
        }
        #expect(recorder.keys == [BrowserPageKey(character: "f", shift: false), BrowserPageKey(character: "f", shift: true)])
        #expect(recorder.escapes == 1)
    }
}
