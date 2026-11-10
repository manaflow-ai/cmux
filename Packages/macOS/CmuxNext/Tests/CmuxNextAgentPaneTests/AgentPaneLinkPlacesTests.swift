@testable import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextSettings
import Testing

/// The places a pasted cmux link names (`linkPlaces`): the page gets `{id, kind, title, host?,
/// workspace?}` entries (webviews chips/cmuxLinkPlaces.ts), only the members that are set.
@MainActor
struct AgentPaneLinkPlacesTests {
    @Test func thePageGetsEachPlaceByItsIdKindAndTitle() {
        let event = AgentPageEvent.linkPlaces([
            .init(id: "ws_16c92e4354fcaf05540386720d78e251", kind: .workspace, title: "Research"),
            .init(id: "tab_0123456789abcdef0123456789abcdef", kind: .tab, title: "zsh", host: "build-box", workspace: "Research"),
        ])
        #expect(event.kind == "linkPlaces")
        #expect(event.value == .array([
            ["id": "ws_16c92e4354fcaf05540386720d78e251", "kind": "workspace", "title": "Research"],
            ["id": "tab_0123456789abcdef0123456789abcdef", "kind": "tab", "title": "zsh", "host": "build-box", "workspace": "Research"],
        ]))
        #expect(AgentPageEvent.linkPlaces([]).value == .array([]))
    }

    /// NIGHTLY 85b099928a8a (Lawrence 2026-11-10, "lots of laggy"): the main thread was ~85% busy in
    /// `follow`'s one observation over every workspace's places. A title change of one tab (an agent's
    /// title spinner) named every tab of every workspace again, under tracking. Each workspace has its
    /// own observation now: a change in one names that workspace only, and the list is the same as a
    /// fresh one.
    @Test func aTitleChangeInOneWorkspaceNamesOnlyThatWorkspace() async throws {
        let count: UInt64 = 40
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        store.apply(snapshot: DaemonTree(workspaces: (1...count).map { id in
            let tabs = (0..<3).map { index in
                TabSnapshot(surface: SurfaceID(rawValue: id * 10 + UInt64(index)), tabResourceID: ResourceID(rawValue: "tab_\(id)_\(index)"),
                            kind: .pty, title: "shell \(id).\(index)")
            }
            let pane = PaneSnapshot(id: PaneID(rawValue: id), resourceID: ResourceID(rawValue: "pane_\(id)"), tabs: tabs)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, resourceID: ResourceID(rawValue: "ws_\(id)"),
                                     name: "w\(id)", screens: [screen])
        }))
        let counts = NamingCounts()
        let titles = AgentPaneLinkPlaces.Titles(workspace: { workspace in
            counts.workspaces += 1
            return workspace.displayName
        }, tabs: { { _, tab in
            counts.tabs += 1
            return tab.displayTitle
        } })
        let places = AgentPaneLinkPlaces()
        places.follow({ [store] in store.workspaces.map { ($0, host: nil) } }, titles: titles)
        func until(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        }
        // 1 workspace + 1 pane + 3 tabs per workspace.
        await until { places.places.count == Int(count) * 5 }
        #expect(places.places.count == Int(count) * 5)

        counts.workspaces = 0
        counts.tabs = 0
        store.apply(.titleChanged(surface: 71, title: "renamed"))
        await until { places.places.contains { $0.id == "tab_7_1" && $0.title == "renamed" } }
        #expect(places.places.contains { $0.id == "tab_7_1" && $0.title == "renamed" })
        #expect(counts.workspaces <= 1, "one tab's title named \(counts.workspaces) of \(count) workspaces again")
        // That workspace's 3 tabs and its pane's front tab.
        #expect(counts.tabs <= 4, "one tab's title named \(counts.tabs) tabs again (\(count) workspaces x 3 tabs)")

        let fresh = store.workspaces.flatMap { workspace -> [AgentPaneLinkPlaces.Place] in
            let name = workspace.displayName
            var list = [AgentPaneLinkPlaces.Place(id: workspace.resourceID?.rawValue ?? "", kind: .workspace, title: name)]
            for pane in workspace.screens.flatMap(\.panes) {
                list.append(.init(id: pane.resourceID?.rawValue ?? "", kind: .pane, title: pane.tabs.first?.displayTitle ?? "", workspace: name))
                list += pane.tabs.map { .init(id: $0.resourceID?.rawValue ?? "", kind: .tab, title: $0.displayTitle, workspace: name) }
            }
            return list
        }
        #expect(places.places == fresh)
    }
}

@MainActor private final class NamingCounts {
    var workspaces = 0
    var tabs = 0
}
