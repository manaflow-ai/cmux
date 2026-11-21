@testable import CmuxNextBrowser
import Foundation
import Testing

/// The predictor's database loads after start-up; an Enter before that taught it nothing (bench `omnibar`:
/// 3 Enters in the first ~2 s after launch, then no prerender). The edit waits and is taught later.
struct OmniboxPendingLearnsTests {
    private func learn(_ text: String, _ url: String) throws -> OmniboxPendingLearns.Learn {
        let opened = try #require(URL(string: url))
        return .init(text: text, matches: [OmniboxPreloadMatch(url: opened, kind: .urlWhatYouTyped)], opened: opened)
    }

    @Test func anEnterBeforeTheDatabaseLoadsIsTaughtOnceItHas() throws {
        var pending = OmniboxPendingLearns()
        let first = try learn("example.com", "https://example.com/")
        let second = try learn("example.com", "https://example.com/")
        pending.ended(first) { _ in 0 }
        pending.ended(second) { _ in 0 }
        var calls: [String] = []
        pending.replay(register: { calls.append("register \($0.text)") },
                       open: { calls.append("open \($0.opened.absoluteString)"); return 1 })
        #expect(calls == ["register example.com", "open https://example.com/",
                          "register example.com", "open https://example.com/"])
        #expect(pending.learns.isEmpty)
    }

    @Test func aLearnThePredictorTookIsNotKept() throws {
        var pending = OmniboxPendingLearns()
        pending.ended(try learn("github.com", "https://github.com/")) { _ in 1 }
        #expect(pending.learns.isEmpty)
    }

    @Test func aReplayBeforeTheDatabaseLoadsKeepsTheRestInOrder() throws {
        var pending = OmniboxPendingLearns()
        let a = try learn("a.com", "https://a.com/"), b = try learn("b.com", "https://b.com/")
        pending.ended(a) { _ in 0 }
        pending.ended(b) { _ in 0 }
        var opened = 0
        pending.replay(register: { _ in }, open: { _ in opened += 1; return 0 })
        #expect(opened == 1)  // still loading: it stops at the first
        #expect(pending.learns == [a, b])
    }

    @Test func everyTextTheEditRegisteredIsTaughtAgainInOrder() throws {
        var pending = OmniboxPendingLearns()
        let url = try #require(URL(string: "https://example.com/"))
        let match = OmniboxPreloadMatch(url: url, kind: .urlWhatYouTyped)
        pending.ended(.init(registrations: [.init(text: "ex", matches: [match]), .init(text: "example.com", matches: [match])],
                            opened: url)) { _ in 0 }
        var registered: [String] = []
        pending.replay(register: { registered.append($0.text) }, open: { _ in 1 })
        #expect(registered == ["ex", "example.com"])
    }

    @Test func anEditTheTabMayNotPreloadIsDroppedUntaught() throws {
        var pending = OmniboxPendingLearns()
        let desktop = try learn("m1", "https://m1.cloud-desktop.localhost/")
        let page = try learn("example.com", "https://example.com/")
        pending.ended(desktop) { _ in 0 }
        pending.ended(page) { _ in 0 }
        var registered: [String] = []
        pending.replay(allowed: { CEFTab.preloads(under: .exceptCloudDesktop, opening: $0.opened) },
                       register: { registered.append($0.text) }, open: { _ in 1 })
        #expect(registered == ["example.com"])
        #expect(pending.learns.isEmpty)
    }

    @Test func atMostCapacityWaitAndTheOldestGoFirst() throws {
        var pending = OmniboxPendingLearns()
        for index in 0...OmniboxPendingLearns.capacity {
            pending.ended(try learn("site\(index).com", "https://site\(index).com/")) { _ in 0 }
        }
        #expect(pending.learns.count == OmniboxPendingLearns.capacity)
        #expect(pending.learns.first?.text == "site1.com")
    }
}
