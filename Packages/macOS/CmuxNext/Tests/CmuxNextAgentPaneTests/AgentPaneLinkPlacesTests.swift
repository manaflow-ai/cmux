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

    /// A Cloud machine's workspace that comes (or goes) names that workspace only, never the local ones
    /// again (review of #40038: a change of the machine-name map re-mapped every workspace).
    @Test func aRemoteWorkspaceThatComesNamesOnlyThatWorkspace() async throws {
        let count: UInt64 = 40
        let local = DaemonStore()
        _ = local.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        local.apply(snapshot: DaemonTree(workspaces: (1...count).map { id in
            let tab = TabSnapshot(surface: SurfaceID(rawValue: id), tabResourceID: ResourceID(rawValue: "tab_\(id)"), kind: .pty, title: "shell \(id)")
            let pane = PaneSnapshot(id: PaneID(rawValue: id), resourceID: ResourceID(rawValue: "pane_\(id)"), tabs: [tab])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, resourceID: ResourceID(rawValue: "ws_\(id)"),
                                     name: "w\(id)", screens: [screen])
        }))
        let remote = DaemonStore()
        _ = remote.apply(.connected(DaemonIdentity(generation: "box-boot"), generationChanged: true))
        let counts = NamingCounts()
        let titles = AgentPaneLinkPlaces.Titles(workspace: { workspace in
            counts.workspaces += 1
            return workspace.displayName
        }, tabs: { { _, tab in tab.displayTitle } })
        let places = AgentPaneLinkPlaces()
        places.follow({ [local, remote] in
            local.workspaces.map { ($0, host: String?.none) } + remote.workspaces.map { ($0, host: String?.some("build-box")) }
        }, titles: titles)
        func until(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        }
        await until { places.places.count == Int(count) * 3 }
        #expect(places.places.count == Int(count) * 3)

        counts.workspaces = 0
        let tab = TabSnapshot(surface: 1, tabResourceID: "tab_box", kind: .pty, title: "remote shell")
        let pane = PaneSnapshot(id: 1, resourceID: "pane_box", tabs: [tab])
        remote.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, resourceID: "ws_box", name: "box",
                                                                         screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])])]))
        await until { places.places.contains { $0.id == "ws_box" } }
        #expect(places.places.contains { $0.id == "ws_box" && $0.host == "build-box" })
        #expect(places.places.contains { $0.id == "tab_box" && $0.host == "build-box" && $0.workspace == "box" })
        #expect(counts.workspaces <= 1, "a remote workspace that came named \(counts.workspaces) workspaces again")
    }
}

@MainActor private final class NamingCounts {
    var workspaces = 0
    var tabs = 0
}
