import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Foundation
import Testing

/// Cmd-Shift-P paints its first frame without the work that frame does not
/// show (Lawrence 2026-10-19: "there is some lag with opening cmd shift p
/// now"). The command page's empty query lists commands; the workspaces and
/// tabs it searches once the user types are read after the first frame, so
/// the open costs the same with 10 workspaces or 5,000 tabs.
@MainActor
@Suite(.paletteRanker, .serialized)
struct PaletteOpenLatencyTests {
    /// Counts reads of its lists: each read is the App walking every
    /// workspace and tab of every machine.
    @MainActor private final class Store: PaletteWorkspaceSource, PaletteTabSource {
        let workspaceList: [PaletteWorkspace]
        let tabList: [PaletteTab]
        var workspaceReads = 0
        var tabReads = 0

        init(workspaces: Int, tabsPerWorkspace: Int) {
            workspaceList = (0..<workspaces).map { index in
                PaletteWorkspace(id: "ws-\(index)", title: "Workspace \(index)", directory: "/Users/me/code/project-\(index)",
                                 groupName: "Group \(index % 12)")
            }
            tabList = (0..<workspaces).flatMap { workspace in
                (0..<tabsPerWorkspace).map { tab in
                    PaletteTab(id: "tab-\(workspace)-\(tab)", title: "zsh — ~/code/project-\(workspace) \(tab)",
                               workspaceTitle: "Workspace \(workspace)", kind: tab % 3 == 0 ? .browser : .terminal)
                }
            }
        }

        var workspaces: [PaletteWorkspace] {
            workspaceReads += 1
            return workspaceList
        }

        var tabs: [PaletteTab] {
            tabReads += 1
            return tabList
        }

        func selectWorkspace(id: String) {}
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
        func selectTab(id: String) {}
        func renameTab(id: String, to title: String) {}
        func closeTab(id: String) {}
    }

    private static func palette(_ store: Store) -> PaletteController {
        _ = NSApplication.shared
        let palette = PaletteController(registry: .standard(), sources: PaletteSources(workspaces: store, tabs: store),
                                        frecencyPersistence: nil)
        palette.prepare(step: 0)
        palette.prepare(step: 1)
        return palette
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    /// The open itself reads no workspace or tab list: the empty query shows
    /// none of them. A typed query finds them once they land.
    @Test func firstFrameReadsNoWorkspaceOrTabList() async {
        let store = Store(workspaces: 40, tabsPerWorkspace: 4)
        let palette = Self.palette(store)
        defer { palette.hide() }
        store.workspaceReads = 0
        store.tabReads = 0
        palette.show(.commands)
        #expect(store.workspaceReads == 0, "the open read every workspace before its first frame")
        #expect(store.tabReads == 0, "the open read every tab before its first frame")
        #expect(!palette.model.rows.isEmpty, "the first frame shows the commands")
        await palette.model.settleDeferredLoads()
        palette.model.send(.setQuery("Workspace 39"))
        await palette.model.settle()
        #expect(palette.model.rows.contains { $0.item.id == "workspace:ws-39" }, "typing finds a workspace")
        #expect(store.workspaceReads == 1, "the workspaces are read once per open, after the first frame")
    }

    /// A warm open's main-thread cost before its frame does not grow with the
    /// user's workspaces and tabs (a heavy user: 600 workspaces, 6,000 tabs).
    @Test func warmOpenCostDoesNotScaleWithWorkspacesAndTabs() async {
        func openCost(_ store: Store) async -> Double {
            let palette = Self.palette(store)
            defer { palette.hide() }
            var samples: [Double] = []
            for _ in 0..<7 {
                let started = ContinuousClock.now
                palette.show(.commands)
                samples.append(Self.milliseconds(started.duration(to: .now)))
                await palette.model.settleDeferredLoads()
                await palette.model.settle()
                palette.hide()
            }
            return samples.sorted()[samples.count / 2]
        }
        let small = await openCost(Store(workspaces: 10, tabsPerWorkspace: 1))
        let large = await openCost(Store(workspaces: 600, tabsPerWorkspace: 10))
        print("palette open (median ms): 10 workspaces/10 tabs \(small), 600 workspaces/6000 tabs \(large)")
        // Same work before the frame: within 2 ms of each other (a scheduling blip, not the data).
        #expect(large - small < 2, "the open's cost grows with the workspaces and tabs: \(small) ms -> \(large) ms")
    }
}
