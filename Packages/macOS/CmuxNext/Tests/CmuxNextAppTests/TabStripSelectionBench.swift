import AppKit
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// tab-switch-rewrite: the strip's part of a tab switch, step by step, over 2, 10, 30 and 60 tabs in a
/// 1400 pt strip (from about 30 tabs it scrolls). Prints `TAB-STRIP-SELECT n=<count> <step>=<µs>`: the
/// whole `syncFromModel` and, apart, each step it runs (selection flags, separators, occlusion, the
/// reveal scroll with and without its spring, the hover card). Timing is printed, not gated.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .closesItsWindows)
struct TabStripSelectionBench {
    @Test(arguments: [2, 10, 30, 60])
    func selectionSteps(_ count: Int) {
        let items = (0..<count).map { TabItem(id: TabID("t\($0)"), title: "Tab number \($0)") }
        let model = TabStripModel(tabs: items, selectedID: items.first?.id)
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        strip.frame = NSRect(x: 0, y: 0, width: 1400, height: 40)
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        strip.syncFromModel()
        func finish() { CATransaction.flush(); _ = CFRunLoopRunInMode(.defaultMode, 0, true) }
        var totals: [String: Double] = [:]
        var runs = 0
        func time(_ name: String, _ body: () -> Void) {
            let start = CACurrentMediaTime()
            body()
            totals[name, default: 0] += (CACurrentMediaTime() - start) * 1e6
        }
        let rounds = max(3, 120 / count)
        for _ in 0..<rounds {
            for item in items {
                model.selectedID = item.id
                time("sync") { strip.syncFromModel() }
                time("separators.full") { TabSeparatorVisibility.apply(to: strip) }
                time("separators.around") { TabSeparatorVisibility.apply(to: strip, around: [item.id]) }
                time("occlusion") { strip.updateOcclusion() }
                time("reveal.spring") { strip.reveal(item.id, animated: true) }
                time("reveal.instant") { strip.reveal(item.id, animated: false) }
                time("hover") { strip.refreshHoverCard() }
                time("finish") { finish() }
                runs += 1
            }
        }
        let line = totals.sorted { $0.value > $1.value }.map { String(format: "%@=%.1fus", $0.key, $0.value / Double(runs)) }
        print("TAB-STRIP-SELECT n=\(count) overflow=\(strip.result.isOverflowing) moves=\(strip.movesInFlight.count) masked=\(strip.occlusionEnds.count) " + line.joined(separator: " "))
        #expect(strip.cells.values.filter(\.isSelected).count == 1)
    }
}
