import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Darwin
import Foundation
import QuartzCore
import Testing

/// u9696 / u9701: the workspace hover card's tab list at "speed of light". A sidebar of 150
/// workspaces x 20 tabs (three panes each, a mix of working, waiting and idle terminals, pages and
/// chats); the card shows each workspace in turn, three passes. Per hover: main-thread CPU of the
/// card's configure, layout, fitting size and Core Animation commit; row views made after the
/// first pass (must be 0: the views are made once and reused); heap bytes still held after the
/// passes (must not grow per hover). The per-tab bytes the cached list adds are reported against
/// the floor. Prints one JSON line, `HOVERCARD_TABS_BENCH {...}`, for the report and the perf gate.
@MainActor @Suite(.serialized) struct WorkspaceHoverCardTabsBench {
    static let workspaces = 150
    static let tabsPerWorkspace = 20
    /// One frame at 120 Hz: the card's whole main-thread cost per hover must fit (p95).
    static let frameBudgetMs = 8.0

    static func tabs(_ w: Int) -> [SidebarTab] {
        (0..<tabsPerWorkspace).map { t in
            let pane = UInt16(t % 3)
            switch t % 5 {
            case 0:
                return SidebarTab(id: TabID("w\(w)t\(t)"), title: "claude", brand: "claude", state: t % 2 == 0 ? .working : .waiting,
                                  detail: "claude: Approve edit to Sources/App/main.swift", pane: pane)
            case 1:
                return SidebarTab(id: TabID("w\(w)t\(t)"), title: "zsh", isUnread: t % 3 == 0, detail: "~/fun/cmux-\(w)", pane: pane)
            case 2:
                return SidebarTab(id: TabID("w\(w)t\(t)"), title: "Pull requests · manaflow-ai/cmux", kind: .browser,
                                  state: t % 4 == 0 ? .busy : .idle, detail: "github.com", pane: pane,
                                  flags: t % 4 == 2 ? [.hibernated] : [.playing])
            case 3:
                return SidebarTab(id: TabID("w\(w)t\(t)"), title: "Fix the sidebar drag", kind: .agentChat, brand: "codex",
                                  state: .working, detail: "Codex", pane: pane)
            default:
                return SidebarTab(id: TabID("w\(w)t\(t)"), title: "cargo test", state: .error, detail: "~/fun/cmux/daemon", pane: pane)
            }
        }.sorted { $0.pane < $1.pane }
    }

    static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }

    static func threadCPUms() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// The tab record before u9696 (id, title, kind, unread, brand, favicon), for the bytes added.
    private struct TabBefore {
        var id: TabID, title: String, kind: SidebarTabKind, isUnread: Bool, brand: String?, favicon: SidebarFavicon?
    }

    @Test func hoverCostWith150WorkspacesOf20Tabs() throws {
        _ = NSApplication.shared
        let heapBeforeTabs = Self.heapInUse()
        let rows = (0..<Self.workspaces).map { w in
            SidebarWorkspace(id: WorkspaceID("w\(w)"), title: "workspace \(w)", directory: "~/fun/cmux-\(w)", branch: "main",
                             activity: .working, tabs: Self.tabs(w))
        }
        let heapTabs = Self.heapInUse() - heapBeforeTabs
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let card = WorkspaceHoverCardView()
        window.contentView = card
        let now = Date()
        func hover(_ workspace: SidebarWorkspace) {
            card.configure(.make(workspace, machine: nil, now: now))
            card.layoutSubtreeIfNeeded()
            _ = card.fittingSize
            CATransaction.flush() // perf-gate-ok: the bench times the card's commit
        }
        // Warm: the first card makes its views and fonts.
        let coldStart = Self.threadCPUms()
        hover(rows[0])
        let coldMs = Self.threadCPUms() - coldStart
        for workspace in rows.prefix(10) { hover(workspace) }
        let viewsAfterWarm = card.tabRowViewsMade
        let heapBefore = Self.heapInUse()
        var samples: [Double] = []
        for _ in 0..<3 {
            for workspace in rows {
                let start = Self.threadCPUms()
                hover(workspace)
                samples.append(Self.threadCPUms() - start)
            }
        }
        let heapGrowth = Self.heapInUse() - heapBefore
        let viewsMade = card.tabRowViewsMade - viewsAfterWarm
        let stride = MemoryLayout<SidebarTab>.stride
        let strideBefore = MemoryLayout<TabBefore>.stride
        let total = Self.workspaces * Self.tabsPerWorkspace
        let report: [String: Any] = [
            "workspaces": Self.workspaces, "tabs_per_workspace": Self.tabsPerWorkspace, "hovers": samples.count,
            "cold_ms": (coldMs * 1000).rounded() / 1000,
            "p50_ms": (Self.percentile(samples, 0.5) * 1000).rounded() / 1000,
            "p95_ms": (Self.percentile(samples, 0.95) * 1000).rounded() / 1000,
            "max_ms": ((samples.max() ?? 0) * 1000).rounded() / 1000,
            "views_made_after_warm": viewsMade,
            "heap_growth_bytes_over_hovers": heapGrowth,
            "tab_stride_bytes": stride, "tab_stride_bytes_before": strideBefore,
            "tab_bytes_added_inline": stride - strideBefore,
            "tabs_inline_bytes_total": stride * total,
            "tabs_heap_bytes_total_measured": heapTabs,
            "card_lines": card.tabLines.count,
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("HOVERCARD_TABS_BENCH " + String(decoding: json, as: UTF8.self))
        #expect(card.tabLines.count == WorkspaceHoverCardView.visibleTabLimit + 2 + 1, "\(card.tabLines)")
        #expect(viewsMade == 0, "a hover made new row views after the first cards")
        // Heap held after 450 hovers: no per-hover growth (a few KB of AppKit caches settle).
        #expect(heapGrowth < 256 * 1024, "the card held \(heapGrowth) bytes more after \(samples.count) hovers")
        #expect(Self.percentile(samples, 0.95) < Self.frameBudgetMs, "p95 \(Self.percentile(samples, 0.95)) ms over one frame")
        window.contentView = nil
        window.close()
    }
}
