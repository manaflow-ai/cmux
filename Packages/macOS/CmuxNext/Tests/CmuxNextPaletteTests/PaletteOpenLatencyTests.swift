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

    /// The main thread's CPU time for `body`: work elsewhere on the host (another app, the next job on a shared
    /// fleet runner) delays the main thread without adding to this. The wall clock counted those delays: under
    /// threads at the highest QoS taking every core, a 1 ms sidebar toggle read 70-90 ms (aws-m4pro-1, 2026-10-21).
    private static func mainThreadCPU(_ body: () -> Void) -> Duration {
        func now() -> Duration {
            var spent = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spent)
            return .seconds(spent.tv_sec) + .nanoseconds(spent.tv_nsec)
        }
        let started = now()
        body()
        return now() - started
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
                samples.append(Self.milliseconds(Self.mainThreadCPU { palette.show(.commands) }))
                await palette.model.settleDeferredLoads()
                await palette.model.settle()
                palette.hide()
            }
            return samples.sorted()[samples.count / 2]
        }
        /// The model stage alone (the page's rows, no panel): what the open costs before AppKit.
        func modelCost(_ store: Store) async -> Double {
            let palette = Self.palette(store)
            var samples: [Double] = []
            for _ in 0..<7 {
                samples.append(Self.milliseconds(Self.mainThreadCPU { palette.model.reset(to: palette.commandsPage()) }))
                await palette.model.settle()
            }
            return samples.sorted()[samples.count / 2]
        }
        let small = await openCost(Store(workspaces: 10, tabsPerWorkspace: 1))
        let large = await openCost(Store(workspaces: 600, tabsPerWorkspace: 10))
        let smallModel = await modelCost(Store(workspaces: 10, tabsPerWorkspace: 1))
        let largeModel = await modelCost(Store(workspaces: 600, tabsPerWorkspace: 10))
        print("palette open (median ms, debug build): 10 workspaces/10 tabs \(small) (model \(smallModel)), "
              + "600 workspaces/6000 tabs \(large) (model \(largeModel))")
        // The page's rows (what this fix owns) cost the same: within 3 ms.
        #expect(largeModel - smallModel < 3, "the open's rows grow with the workspaces and tabs: \(smallModel) ms -> \(largeModel) ms")
        // The whole open (panel order-in and layout vary by a few ms) stays
        // within 8 ms; before the fix it grew by about 70 ms.
        #expect(large - small < 8, "the open's cost grows with the workspaces and tabs: \(small) ms -> \(large) ms")
    }
}
