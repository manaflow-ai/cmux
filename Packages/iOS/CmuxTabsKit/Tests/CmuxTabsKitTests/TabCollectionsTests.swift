@testable import CmuxTabsKit
import Foundation
import Testing

struct TabCollectionsTests {
    @Test func pinnedItemsComeFirstInPinOrder() {
        var p = TabPins()
        p.pin("c"); p.pin("a")
        #expect(p.arranged(["a", "b", "c", "d"]) == ["c", "a", "b", "d"])
        #expect(p.count(in: ["a", "b", "c", "d"]) == 2)
        p.unpin("c")
        #expect(p.arranged(["a", "b", "c", "d"]) == ["a", "b", "c", "d"])
    }

    @Test func pinsOfClosedTabsAreIgnoredAndDropped() {
        var p = TabPins(keys: ["gone", "b"])
        #expect(p.arranged(["a", "b"]) == ["b", "a"])
        #expect(p.count(in: ["a", "b"]) == 1)
        p.retain(["a", "b"])
        #expect(p.keys == ["b"])
    }

    @Test func pinsPersistPerHost() {
        let d = UserDefaults(suiteName: "TabCollectionsTests")!
        d.removePersistentDomain(forName: "TabCollectionsTests")
        TabPins(keys: ["x"]).save(host: "h1", to: d)
        #expect(TabPins.load(host: "h1", from: d).keys == ["x"])
        #expect(TabPins.load(host: "h2", from: d).keys.isEmpty)
    }

    @Test func selectionTogglesAndBulkActionsFollowGridOrder() {
        var s = TabSelection()
        s.toggle("c"); s.toggle("a"); s.toggle("b"); s.toggle("b")
        #expect(s.count == 2 && s.contains("a") && !s.contains("b"))
        #expect(s.keys(in: ["a", "b", "c"]) == ["a", "c"])
        #expect(s.title == "2 selected" && s.closeTitle == "Close 2 Tabs")
        #expect(s.pinTitle == "Pin 2 Tabs" && s.copyTitle == "Copy 2 Links")
        s.retain(["c"])
        #expect(s.keys(in: ["a", "c"]) == ["c"] && s.closeTitle == "Close 1 Tab")
    }
}
