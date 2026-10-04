import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing
@testable import CmuxNextBridge

/// App screens reach the layout (plans/cmux-next/app-screens.md 3) only from
/// a daemon that serves `app-screens-v1`; without it every screen maps as an
/// ordinary screen.
@MainActor
struct AppScreenMappingTests {
    private func workspace(_ screens: [ScreenSnapshot]) throws -> WorkspaceModel {
        let snapshot = WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02"), name: "App",
                                         screens: screens)
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [snapshot]))
        return try #require(store.workspaces.first)
    }

    private var appTab: TabSnapshot { TabSnapshot(surface: 5, kind: .app, title: "App Store", app: "app-store") }

    @Test func anAppScreenIsOneChromelessColumnOverTheScreen() throws {
        let screen = ScreenSnapshot(id: 4, layout: .leaf(3), panes: [PaneSnapshot(id: 3, tabs: [appTab])], kind: .app, app: "app-store")
        let mapped = try #require(LayoutMapping.shared.map(try workspace([screen]), appScreens: true).screens.first)
        #expect(mapped.kind == .app("app-store"))
        let columns = mapped.layout.columns
        #expect(columns.count == 1)
        #expect(columns.first?.id == mapped.implicitColumnID)
        #expect(columns.first?.app == "app-store")
        #expect(columns.first?.dock == nil)
        #expect(mapped.layout.chromelessPanes == Set(mapped.layout.panes))
        #expect(mapped.layout.panes.count == 1)
    }

    /// Without `app-screens-v1` an app screen is an ordinary screen: no
    /// kind, no app mark, no chromeless pane.
    @Test func withoutTheCapabilityEveryScreenIsOrdinary() throws {
        let app = ScreenSnapshot(id: 4, layout: .leaf(3), panes: [PaneSnapshot(id: 3, tabs: [appTab])], kind: .app, app: "app-store")
        let screens = LayoutMapping.shared.map(try workspace([app])).screens
        #expect(screens.map(\.kind) == [.workspace])
        #expect(screens[0].layout == .splits(.leaf(screens[0].layout.panes[0])))
        #expect(screens[0].layout.chromelessPanes.isEmpty)
    }

    /// v1 has only `app` screens (R90): an `appColumn` tree maps to an
    /// ordinary screen with its columns and their chrome.
    @Test func anAppColumnTreeMapsToAnOrdinaryScreen() throws {
        let json = #"""
        {"id":4,"layout":{"type":"leaf","pane":3},"kind":"appColumn","app":"home",
         "columns":[{"id":9,"width":0.3,"layout":{"type":"leaf","pane":3},"sticky":{"edge":"left","mode":"docked"},"app":"home"},
                    {"id":8,"width":0.7,"layout":{"type":"leaf","pane":7}}],
         "panes":[{"id":3,"tabs":[{"surface":5,"kind":"app","app":"home"}]},{"id":7,"tabs":[{"surface":6}]}]}
        """#
        let screen = try JSONDecoder().decode(ScreenSnapshot.self, from: Data(json.utf8))
        let lone = try JSONDecoder().decode(ScreenSnapshot.self, from: Data(
            #"{"id":14,"layout":{"type":"leaf","pane":13},"kind":"appColumn","app":"home","panes":[{"id":13,"tabs":[{"surface":15}]}]}"#.utf8))
        let screens = LayoutMapping.shared.map(try workspace([screen, lone]), appScreens: true).screens
        #expect(screens.map(\.kind) == [.workspace, .workspace])
        #expect(screens[0].layout.columns.count == 2)
        #expect(screens.allSatisfy { $0.layout.chromelessPanes.isEmpty })
        #expect(screens[1].layout == .splits(.leaf(screens[1].layout.panes[0])))
    }

    @Test func anOrdinaryScreenStaysOrdinary() throws {
        let screen = ScreenSnapshot(id: 4, layout: .leaf(3), panes: [PaneSnapshot(id: 3, tabs: [TabSnapshot(surface: 5)])])
        let mapped = try #require(LayoutMapping.shared.map(try workspace([screen]), appScreens: true).screens.first)
        #expect(mapped.kind == .workspace)
        #expect(mapped.layout.chromelessPanes.isEmpty)
    }
}
