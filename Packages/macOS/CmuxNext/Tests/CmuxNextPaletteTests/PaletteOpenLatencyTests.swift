import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Foundation
import Testing

/// Cmd-Shift-P paints its first frame without the work that frame does not
/// show (Lawrence 2026-10-19: "there is some lag with opening cmd shift p
/// now"). The command page's empty query lists commands; the workspaces and
/// tabs it searches once the user types are read after the first frame, so
/// the open costs the same with 10 workspaces or 5,000 tabs.
@MainActor
@Suite(.paletteRanker, .serialized, .closesItsWindows)
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
        defer { palette.closeForTest() }
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

    /// Go to Workspace (Cmd-P) lists the workspaces on its empty query, so its
    /// open reads the list, but once: every read walks every workspace of
    /// every machine. Since #27071 the open asked each provider for its
    /// immediate rows twice (once for the rows, once to see whether it must
    /// refresh them), which built every row of the page twice, the command
    /// page's row per catalog action included.
    @Test func goToWorkspaceOpenReadsTheWorkspaceListOnce() throws {
        let store = Store(workspaces: 40, tabsPerWorkspace: 4)
        let palette = Self.palette(store)
        defer { palette.closeForTest() }
        let page = try #require(palette.workspacesPage())
        store.workspaceReads = 0
        palette.model.reset(to: page)
        #expect(!palette.model.rows.isEmpty, "the first frame shows the workspaces")
        #expect(store.workspaceReads == 1, "the open read the workspaces \(store.workspaceReads) times")
    }

    /// A warm open's main-thread work before its frame does not grow with the
    /// user's workspaces and tabs (a heavy user: 600 workspaces, 6,000 tabs).
    ///
    /// The page's rows (what the deferred load owns) are counted, not timed: a warm open
    /// reads no workspace or tab list and builds the same rows at 10 workspaces as at 600.
    /// Timing them gave the full suite's run noise, not growth: with every suite running
    /// beside this one the model stage's median read 80-105 ms, and its 600-workspace minus
    /// 10-workspace difference read +19.8 ms (6687c32f), +4.6 ms (#28298's run) and
    /// -15.0 ms (6fcb117f45). A real growth cannot be negative.
    ///
    /// The whole open (panel order-in and layout) is still timed, relatively: the small and
    /// large opens alternate, so both see the same load on the host, and each takes its
    /// cheapest sample, since the host only ever adds time. Before the deferred load the
    /// large open cost about 70 ms more than the small one's 14 ms.
    @Test func warmOpenCostDoesNotScaleWithWorkspacesAndTabs() async {
        let smallStore = Store(workspaces: 10, tabsPerWorkspace: 1)
        let largeStore = Store(workspaces: 600, tabsPerWorkspace: 10)

        /// One warm open of the model stage alone (the page's rows, no panel): its main-thread
        /// time, the workspace and tab lists it read, and the rows it built.
        func modelOpen(_ palette: PaletteController, _ store: Store) -> (ms: Double, reads: Int, rows: Int) {
            let before = store.workspaceReads + store.tabReads
            let spent = Self.mainThreadCPU { palette.model.reset(to: palette.commandsPage()) }
            return (Self.milliseconds(spent), store.workspaceReads + store.tabReads - before,
                    palette.model.current?.items.count ?? -1)
        }
        let smallModel = Self.palette(smallStore), largeModel = Self.palette(largeStore)
        defer {
            smallModel.closeForTest()
            largeModel.closeForTest()
        }
        var smallModelOpens: [(ms: Double, reads: Int, rows: Int)] = []
        var largeModelOpens: [(ms: Double, reads: Int, rows: Int)] = []
        for _ in 0..<7 {
            // Settled: the open before this one loaded every workspace and tab into its page.
            smallModelOpens.append(modelOpen(smallModel, smallStore))
            await smallModel.model.settle()
            largeModelOpens.append(modelOpen(largeModel, largeStore))
            await largeModel.model.settle()
        }

        func timedOpen(_ palette: PaletteController) async -> Double {
            let spent = Self.milliseconds(Self.mainThreadCPU { palette.show(.commands) })
            await palette.model.settleDeferredLoads()
            await palette.model.settle()
            palette.hide()
            return spent
        }
        let smallPalette = Self.palette(smallStore), largePalette = Self.palette(largeStore)
        defer {
            smallPalette.closeForTest()
            largePalette.closeForTest()
        }
        var smallOpens: [Double] = [], largeOpens: [Double] = []
        for _ in 0..<7 {
            smallOpens.append(await timedOpen(smallPalette))
            largeOpens.append(await timedOpen(largePalette))
        }

        let small = smallOpens.min() ?? 0, large = largeOpens.min() ?? 0
        print("palette open (cheapest of 7, ms, debug build): 10 workspaces/10 tabs \(small) "
              + "(model \(smallModelOpens.map(\.ms).min() ?? 0)), 600 workspaces/6000 tabs \(large) "
              + "(model \(largeModelOpens.map(\.ms).min() ?? 0))")
        // Every warm open reads no list before its frame and builds the same rows at either size.
        #expect(smallModelOpens.allSatisfy { $0.reads == 0 } && largeModelOpens.allSatisfy { $0.reads == 0 },
                "a warm open read the workspace or tab list before its frame")
        #expect(largeModelOpens.map(\.rows) == smallModelOpens.map(\.rows),
                "the open's rows grow with the workspaces and tabs: \(smallModelOpens.map(\.rows)) -> \(largeModelOpens.map(\.rows))")
        #expect(smallModelOpens.allSatisfy { $0.rows > 0 }, "the open builds the command rows")
        // The whole open grows by less than it costs (or 8 ms when it costs less): flat opens differ
        // only by what the host adds, while one that builds a row per tab grew about 5x.
        #expect(large - small < max(8, small), "the open's cost grows with the workspaces and tabs: \(small) ms -> \(large) ms")
    }
}
