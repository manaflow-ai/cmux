@testable import CmuxNextApp
import Testing

/// After each create, every open New Tab page gets its places (open tabs and workspaces). They
/// were built once per page (a walk of every tab of every workspace, with icons, per page, in the
/// frames after the key); now once per window's shown workspace, and again only for a page that
/// is itself a place (its chat started), which gets the list without itself (c87d0466632).
@MainActor
struct NewTabPlacesSharedBuildTests {
    private final class Builds {
        var calls: [(excluding: String?, current: String?)] = []
    }

    /// Places are the listed page keys; `extra` keys are places that are pages too.
    private static func run(_ pages: [(key: String, current: String?)], places extra: [String] = [], builds: Builds) -> [String: [String]] {
        NewTabPlacesFeed.sharedPlaces(for: pages, build: { excluding, current in
            builds.calls.append((excluding, current))
            return (["tab-a", "tab-b"] + extra).filter { $0 != excluding }
        }, lists: { places, key in places.contains(key) })
    }

    @Test(arguments: [1, 2, 8, 24])
    func pagesOfOneWindowShareOneBuild(count: Int) {
        let builds = Builds()
        let pages = (0..<count).map { (key: "page-\($0)", current: Optional("ws-1")) }
        let places = Self.run(pages, builds: builds)
        #expect(builds.calls.count == 1, "\(count) open pages built the places \(builds.calls.count) times")
        #expect(places.count == count)
        #expect(places.values.allSatisfy { $0 == ["tab-a", "tab-b"] })
    }

    @Test func eachShownWorkspaceBuildsOnce() {
        let builds = Builds()
        let pages = [("p1", "ws-1"), ("p2", "ws-2"), ("p3", "ws-1"), ("p4", "ws-2")].map { (key: $0.0, current: Optional($0.1)) }
        _ = Self.run(pages, builds: builds)
        #expect(builds.calls.count == 2)
    }

    @Test func aPageThatIsAPlaceGetsTheListWithoutItself() {
        let builds = Builds()
        let places = Self.run([("p1", "ws-1"), ("chat-page", "ws-1")].map { (key: $0.0, current: Optional($0.1)) },
                              places: ["chat-page"], builds: builds)
        #expect(places["p1"] == ["tab-a", "tab-b", "chat-page"])
        #expect(places["chat-page"] == ["tab-a", "tab-b"])
        #expect(builds.calls.count == 2)
    }
}
