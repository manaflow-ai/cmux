import CmuxNextCompat
import Testing

/// The reverse side of a ``ManyToOneIndex`` follows every write: a key re-pointed, removed by nil
/// or by `removeValue(forKey:)`, and a value whose last key went.
@Suite struct ManyToOneIndexTests {
    @Test func theReverseSideFollowsEveryWrite() {
        var index = ManyToOneIndex<String, String>()
        index["provisional"] = "page"
        index["real"] = "page"
        index["other"] = "elsewhere"
        #expect(index.keys(for: "page") == ["provisional", "real"])
        #expect(Set(index.values) == ["page", "elsewhere"])

        index["other"] = "page" // re-pointed: it leaves its old value
        #expect(index.keys(for: "page") == ["provisional", "real", "other"])
        #expect(!index.contains(value: "elsewhere"))

        index["provisional"] = nil
        #expect(index.removeValue(forKey: "other") == "page")
        #expect(index.keys(for: "page") == ["real"])
        #expect(index["provisional"] == nil)

        index["real"] = "page" // the same value again: no change
        #expect(index.keys(for: "page") == ["real"])
        index.removeValue(forKey: "real")
        #expect(!index.contains(value: "page"))
        #expect(index.keys(for: "page").isEmpty)
        #expect(index.removeValue(forKey: "real") == nil)
    }
}
