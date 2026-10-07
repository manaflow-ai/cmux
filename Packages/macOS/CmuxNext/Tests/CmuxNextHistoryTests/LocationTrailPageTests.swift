import CmuxNextHistory
import Foundation
import Testing

/// Top pages in the trail (TOP-SECTION-ITEMS-ARE-PAGES Q2, coordinator
/// approval of the additive format): a page the user shows is a trail
/// entry; Back and Forward reach it in the window's trail; the stored trail
/// stays readable by builds without pages, which skip such entries.
struct LocationTrailPageTests {
    static let t0 = Date(timeIntervalSince1970: 2_000_000)

    static func tab(_ id: String, workspace: String = "A", window: String = "w1") -> HistoryLocation {
        HistoryLocation(key: .init(machine: "home", tab: id), window: window, workspace: workspace, pane: "p-\(id)",
                        content: .terminal, title: id)
    }

    static func trail(_ locations: [HistoryLocation]) -> LocationTrail {
        var trail = LocationTrail()
        for (index, location) in locations.enumerated() { trail.record(location, at: t0.addingTimeInterval(Double(index) * 2)) }
        return trail
    }

    /// Record a page, then a tab: Back lands on the page in both scopes;
    /// from the page, Back reaches the window's earlier tab.
    @Test func backReachesAPageAndBackFromAPageReachesTheWorkspace() {
        var trail = Self.trail([Self.tab("a"), .page("home", window: "w1", title: "Home"), Self.tab("b")])
        #expect(trail.back(scope: .workspace)?.location.page == "home")
        var windowScope = Self.trail([Self.tab("a"), .page("home", window: "w1", title: "Home"), Self.tab("b")])
        #expect(windowScope.back(scope: .window)?.location.page == "home")
        var fromPage = Self.trail([Self.tab("a"), .page("home", window: "w1", title: "Home")])
        #expect(fromPage.back(scope: .workspace)?.location.key.tab == "a")
    }

    /// A page of another window is out of scope.
    @Test func anotherWindowsPageIsOutOfScope() {
        var trail = Self.trail([.page("home", window: "w2", title: "Home"), Self.tab("b")])
        #expect(trail.back(scope: .workspace) == nil)
        #expect(trail.back(scope: .window) == nil)
    }

    /// A trail stored by a build without pages (no "page" key) still loads.
    @Test func theOldFormatDecodes() throws {
        let old = #"{"key":{"machine":"home","tab":"t1"},"window":"w1","workspace":"A","pane":"p1","content":"terminal","title":"t","isIncognito":false}"#
        let location = try JSONDecoder().decode(HistoryLocation.self, from: Data(old.utf8))
        #expect(location.page == nil)
        #expect(location.key.tab == "t1")
    }

    /// A build without pages reads the new format: the extra key is ignored
    /// and the page entry looks like a tab that does not exist.
    @Test func aDecoderWithoutPagesReadsTheNewFormat() throws {
        let data = try JSONEncoder().encode(HistoryLocation.page("page:app-store", window: "w1", title: "App Store"))
        let older = try JSONDecoder().decode(OlderLocation.self, from: data)
        #expect(older.key.machine == HistoryLocation.pageMachine)
        #expect(older.key.tab == "page:app-store")
        #expect(older.content == "other")
    }

    /// A mixed trail written and read back by this build keeps page entries in order.
    @Test func aMixedTrailRoundTripsInOrder() throws {
        let trail = Self.trail([Self.tab("a"), .page("home", window: "w1", title: "Home"), Self.tab("b"),
                                .page("page:app-store", window: "w1", title: "App Store")])
        let decoded = try JSONDecoder().decode(LocationTrail.self, from: JSONEncoder().encode(trail.persistable))
        #expect(decoded.entries.map { $0.location.page ?? $0.location.key.tab } == ["a", "home", "b", "page:app-store"])
        #expect(decoded.current?.location.page == "page:app-store")
    }

    /// The location shape of a build without pages.
    struct OlderLocation: Decodable {
        struct Key: Decodable { var machine: String; var tab: String }
        var key: Key
        var window: String
        var workspace: String
        var pane: String
        var content: String
        var title: String
        var isIncognito: Bool
    }
}
