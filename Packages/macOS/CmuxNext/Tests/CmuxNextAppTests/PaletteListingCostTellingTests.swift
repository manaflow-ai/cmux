import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextTestSupport
import Foundation
import Testing

/// Telling rows, print only: they want nothing. The cost of one whole listing of the Commands palette's actions
/// (`PaletteController.commandListing()`), which the New Tab page's bar reads in slices
/// (`AgentPaneNewTabActions.slice`), one slice in a task of the main thread's background work.
///
/// Row 1 reads 20 listings in one call each, 20 listings in slices with no pause, and 3 listings in slices with a
/// pause of 100 ms between two slices (a test process has about that time between two frames). Row 2 is the flow of
/// `NewTabOpenFramesTests.cmdNsFirstPageGetsThePalettesActions` with the count of the lister's tasks.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct PaletteListingCostTellingTests {
    static func milliseconds(_ time: Duration) -> Double {
        (Double(time.components.seconds) + Double(time.components.attoseconds) / 1e18) * 1000
    }

    static func words(_ values: [Double]) -> String {
        let sorted = values.sorted()
        guard let least = sorted.first, let most = sorted.last else { return "no value" }
        return String(format: "the least %.2f ms, the middle %.2f ms, the most %.2f ms", least, sorted[sorted.count / 2], most)
    }

    /// One listing read in slices: the count of slices, the time in them, the count of rows.
    static func sliced(_ services: AppServices, pause: Duration?) async throws -> (slices: Int, spent: Double, rows: Int) {
        let listing = services.palette.commandListing()
        var slices = 0, spent = Duration.zero
        var entries: [PaletteCommandEntry]?
        while entries == nil {
            let start = ContinuousClock.now
            entries = listing.step(until: .now + AgentPaneNewTabActions.slice)
            spent += ContinuousClock.now - start
            slices += 1
            if entries == nil, let pause { try await Task.sleep(for: pause) }
        }
        return (slices, milliseconds(spent), entries?.count ?? 0)
    }

    @Test func aWholeListingOfThePalettesActions() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-palette-listing-cost")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            _ = try await NewTabOpenFramesTests.focusedPane(services)
            var whole: [Double] = [], rows: [Int] = []
            var tight: [(slices: Int, spent: Double, rows: Int)] = []
            for _ in 0..<20 {
                let start = ContinuousClock.now
                let listing = services.palette.commandListing()
                var entries: [PaletteCommandEntry]?
                while entries == nil { entries = listing.step(until: .now + .seconds(5)) }
                whole.append(Self.milliseconds(ContinuousClock.now - start))
                rows.append(entries?.count ?? 0)
                try await Task.sleep(for: .milliseconds(20))
                tight.append(try await Self.sliced(services, pause: nil))
                try await Task.sleep(for: .milliseconds(20))
            }
            var paused: [(slices: Int, spent: Double, rows: Int)] = []
            for _ in 0..<3 { paused.append(try await Self.sliced(services, pause: .milliseconds(100))) }
            print("""
                PaletteListingCostTellingTests: a whole listing of the palette's actions. 20 listings in one call each: \
                \(Self.words(whole)); rows of each: \(Set(rows).sorted()). 20 listings in slices with no pause: slices of each \
                \(tight.map(\.slices)), time in the slices: \(Self.words(tight.map(\.spent))); rows of each: \
                \(Set(tight.map(\.rows)).sorted()). 3 listings in slices with a pause of 100 ms between two slices: slices of \
                each \(paused.map(\.slices)), time in the slices of each \(paused.map { String(format: "%.1f ms", $0.spent) }); \
                rows of each: \(Set(paused.map(\.rows)).sorted())
                """)
        }
    }

    @Test func theBarsListingForAFirstPage() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-palette-listing-flow")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let tabs = services.agentTabs, budget = services.mainWork.budget
            BenchSpans.begin()
            _ = try await NewTabOpenFramesTests.focusedPane(services)
            let atStart = budget.stats, clock = ContinuousClock.now
            let made = try #require(tabs.firstPage(cwd: nil, token: nil), "no first page")
            let key = "palette-listing-flow-\(UUID().uuidString.prefix(8))"
            tabs.newTabPages[key] = made
            defer { tabs.newTabPages[key] = nil }
            var came: Double?
            while came == nil, ContinuousClock.now - clock < .seconds(60) {
                if tabs.newTabPages[key]?.page.omnibar.actions.isEmpty == false {
                    came = Self.milliseconds(ContinuousClock.now - clock) / 1000
                } else {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            let tasks = BenchSpans.end().filter { $0.name == "newTab.paletteActions" }
            let stats = budget.stats
            let cameWords = came.map { String(format: "after %.1f s", $0) } ?? "not in 60 s"
            let rows = tabs.newTabPages[key]?.page.omnibar.actions.count ?? 0
            print("""
                PaletteListingCostTellingTests: the bar's listing for a first page: the actions came \(cameWords); rows: \(rows); \
                the lister ran \(tasks.count) tasks, time in them: \(String(format: "%.1f ms", tasks.map(\.milliseconds).reduce(0, +))); \
                background tasks in all: \(stats.tasks[2] - atStart.tasks[2]); frames: \(stats.frames - atStart.frames); \
                waits for a frame with idle time: \(stats.waitedForIdleFrame - atStart.waitedForIdleFrame)
                """)
        }
    }
}
