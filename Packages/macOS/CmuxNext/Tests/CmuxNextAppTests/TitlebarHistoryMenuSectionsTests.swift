import CmuxNextHistory
import Foundation
import Testing

/// The titlebar Back / Forward right-click list (history.md 4.2c): the scope's
/// entries, then the window's other places, or every place split by kind.
struct TitlebarHistoryMenuSectionsTests {
    static func place(_ tab: String, workspace: String, content: HistoryLocation.Content = .terminal,
                      page: String? = nil, window: String = "w1") -> HistoryLocation {
        HistoryLocation(key: .init(machine: "m", tab: tab), window: window, workspace: workspace, pane: "p-\(tab)",
                        content: content, title: tab, page: page)
    }

    /// A trail of `places` recorded 10 s apart (no coalescing), cursor on the last.
    static func trail(_ places: [HistoryLocation]) -> LocationTrail {
        var trail = LocationTrail()
        for (step, place) in places.enumerated() {
            _ = trail.record(place, at: Date(timeIntervalSince1970: TimeInterval(step * 10)))
        }
        return trail
    }

    static func titles(_ section: LocationTrailMenuSection) -> [String] { section.items.map(\.entry.location.title) }

    @Test func otherWorkspacesFollowTheScope() {
        let trail = Self.trail([Self.place("a", workspace: "one"), Self.place("b", workspace: "two"),
                                Self.place("c", workspace: "one")])
        let sections = trail.menuSections(.back, scope: .workspace, layout: .scopeThenWindow)
        #expect(sections.map(\.kind) == [.scope, .otherWorkspaces])
        #expect(Self.titles(sections[0]) == ["a"])
        #expect(Self.titles(sections[1]) == ["b"])
    }

    @Test func theScopeLayoutIsTheOldList() {
        let trail = Self.trail([Self.place("b", workspace: "two"), Self.place("c", workspace: "one")])
        #expect(trail.menuSections(.back, scope: .workspace, layout: .scope).isEmpty)
        let window = trail.menuSections(.back, scope: .workspace, layout: .scopeThenWindow)
        #expect(window.map(\.kind) == [.otherWorkspaces])
    }

    @Test func otherWorkspacesListEachPlaceOnceNearestFirst() {
        let trail = Self.trail([Self.place("b", workspace: "two"), Self.place("d", workspace: "three"),
                                Self.place("b", workspace: "two"), Self.place("c", workspace: "one")])
        let others = trail.menuSections(.back, scope: .workspace, layout: .scopeThenWindow).first { $0.kind == .otherWorkspaces }
        #expect(others.map(Self.titles) == ["b", "d"])
        #expect(others?.items.first?.index == 2)
    }

    @Test func windowScopeAddsNoSecondSection() {
        let trail = Self.trail([Self.place("b", workspace: "two"), Self.place("c", workspace: "one")])
        #expect(trail.menuSections(.back, scope: .window, layout: .scopeThenWindow).map(\.kind) == [.scope])
    }

    @Test func otherWindowsStayOut() {
        let trail = Self.trail([Self.place("x", workspace: "two", window: "w2"), Self.place("c", workspace: "one")])
        #expect(trail.menuSections(.back, scope: .workspace, layout: .scopeThenWindow).isEmpty)
    }

    @Test func byKindSplitsBrowserChatsAndTerminals() {
        let trail = Self.trail([
            Self.place("site", workspace: "one", content: .browser),
            Self.place("chat", workspace: "two", content: .other),
            Self.place("shell", workspace: "two"),
            Self.place("store", workspace: "", content: .other, page: "appStore"),
            Self.place("now", workspace: "one"),
        ])
        let sections = trail.menuSections(.back, scope: .workspace, layout: .byKind)
        #expect(sections.map(\.kind) == [.browser, .chatsAndPages, .terminals])
        #expect(sections.map(Self.titles) == [["site"], ["store", "chat"], ["shell"]])
    }

    @Test func forwardListsTheEntriesAfterTheCursor() {
        var trail = Self.trail([Self.place("a", workspace: "one"), Self.place("b", workspace: "two"),
                                Self.place("c", workspace: "one")])
        _ = trail.back(scope: .workspace)
        let sections = trail.menuSections(.forward, scope: .workspace, layout: .scopeThenWindow)
        #expect(sections.map(Self.titles) == [["c"], ["b"]])
    }

    @Test func surfaceScopeLeavesItToThePage() {
        let trail = Self.trail([Self.place("a", workspace: "one"), Self.place("c", workspace: "one")])
        for layout in LocationTrailMenuLayout.allCases {
            #expect(trail.menuSections(.back, scope: .surface, layout: layout).isEmpty)
        }
    }

    @Test func addedSectionsAreCapped() {
        let many = (0..<20).map { Self.place("t\($0)", workspace: "w\($0)") }
        let trail = Self.trail(many + [Self.place("now", workspace: "home")])
        let others = trail.menuSections(.back, scope: .workspace, layout: .scopeThenWindow).first { $0.kind == .otherWorkspaces }
        #expect(others?.items.count == LocationTrail.menuSectionLimit)
        #expect(others?.items.first?.entry.location.title == "t19")
    }
}
