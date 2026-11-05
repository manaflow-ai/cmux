import AppKit
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// tab-switch-rewrite: a tab switch updates only the separator lines around the two tabs whose
/// selection changed (O(1) at any tab count). After any sequence of switches, every line must be
/// what the full pass over the row (`TabSeparatorVisibility.apply(to:)`) would draw.
@MainActor @Suite(.serialized, .closesItsWindows)
struct TabStripSwitchSeparatorTests {
    private func strip(tabs count: Int) -> (TabStripView, TabStripModel, NSWindow) {
        let items = (0..<count).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let model = TabStripModel(tabs: items, selectedID: items.first?.id)
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        strip.frame = NSRect(x: 0, y: 0, width: 1400, height: 40)
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        strip.syncFromModel()
        return (strip, model, window)
    }

    private func lines(_ strip: TabStripView) -> [TabID: Bool] {
        strip.cells.mapValues(\.showsSeparator)
    }

    @Test(arguments: [3, 12, 40])
    func switchesLeaveTheLinesAFullPassDraws(_ count: Int) {
        let (strip, model, window) = strip(tabs: count)
        defer { window.close() }
        var order = Array(0..<count)
        order += [count - 1, 0, count / 2, count / 2 + 1, count / 2, 1, count - 2]
        for index in order where index >= 0 && index < count {
            model.selectedID = TabID("t\(index)")
            strip.syncFromModel()
            let fast = lines(strip)
            TabSeparatorVisibility.apply(to: strip)
            #expect(lines(strip) == fast, "after selecting t\(index) of \(count), the lines differ from a full pass")
            #expect(strip.cells[TabID("t\(index)")]?.isSelected == true)
            #expect(strip.cells.values.filter(\.isSelected).count == 1)
        }
    }
}
