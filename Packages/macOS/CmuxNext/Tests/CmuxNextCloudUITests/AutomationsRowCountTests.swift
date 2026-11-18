import AppKit
@testable import CmuxNextCloudUI
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import SwiftUI
import Testing

/// The row ids a list reported as it drew (`EnvironmentValues.rowDrawn`).
@MainActor private final class Draws {
    var ids: [String] = []

    /// The ids drawn since the last take, then forgets them.
    func take() -> [String] {
        defer { ids = [] }
        return ids
    }
}

/// Leo 2026-11-18: "we draw the visible area, right?" The Automations list draws the rows in view at
/// 100 automations as at 10,000, and a change draws only the rows it changed: a new selection draws
/// the old and the new row, a reload of the same rows draws none, and the page groups and sorts its
/// rows once per load, never once per body. Each run prints its counts ("automations-row-counts").
@MainActor @Suite(.serialized, .closesItsWindows) struct AutomationsRowCountTests {
    /// Friday 2026-10-30 08:00 local.
    static let now: Date = {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 30, 8, 0)
        return Calendar.current.date(from: c)!
    }()

    /// `count` enabled automations, all under Later, in id order.
    static func rows(_ count: Int) -> [AutomationRow] {
        (0..<count).map { i in
            AutomationRow(id: "rc\(count)-\(i)", name: "Automation \(i)", target: i.isMultiple(of: 2) ? .thisMac : .cloud,
                          schedule: "every 30m", task: "task \(i)", enabled: true,
                          nextRun: now.addingTimeInterval(2 * 86_400 + Double(i)), last: .succeeded)
        }
    }

    /// Lets SwiftUI apply what changed, then lays the page out.
    static func settle(_ view: NSView) {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            view.layoutSubtreeIfNeeded()
        }
    }

    /// The row ids `change` drew, in draw order.
    fileprivate static func drawn(_ view: NSView, _ probe: Draws, _ change: () -> Void) -> [String] {
        _ = probe.take()
        change()
        settle(view)
        return probe.take()
    }

    @Test(arguments: [100, 10_000])
    func theListDrawsTheRowsInViewAndAChangeDrawsOnlyItsRows(count: Int) throws {
        _ = NSApplication.shared
        let rows = Self.rows(count)
        let page = AutomationsPage(rows: rows, selection: rows[0].id)
        let palette = AutomationsPalette(tokens: ThemeScope.app.tokens)
        let height: CGFloat = 600
        let probe = Draws()
        let view = AutomationsPageView(page: page, palette: palette, now: Self.now)
        let host = NSHostingView(rootView: view.environment(\.rowDrawn) { probe.ids.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: height)
        window.orderFrontRegardless()

        let mounted = Set(Self.drawn(host, probe) { Self.settle(host) }).count
        // A row is at least 30 points tall; one viewport of overscan each side.
        let bound = 3 * Int(height / 30)
        let builds = page.sectionBuilds
        let selection = Self.drawn(host, probe) { page.selection = rows[1].id }
        let selectionBuilds = page.sectionBuilds - builds
        let same = Self.drawn(host, probe) { page.selection = rows[1].id }
        print("automations-row-counts n=\(count) mounted=\(mounted) bound=\(bound) selection=\(selection.count) "
            + "selection_sorts=\(selectionBuilds) reselect=\(same.count)")

        #expect(mounted > 0 && mounted <= bound, "rows drawn at mount: \(mounted), viewport and overscan hold \(bound)")
        #expect(Set(selection) == [rows[0].id, rows[1].id],
                "a new selection draws the old and the new row only, drew \(selection.count): \(selection.prefix(8))")
        #expect(selectionBuilds == 0, "a selection sorted the \(count) rows \(selectionBuilds) times")
        #expect(same.isEmpty, "the same selection again drew \(same.count) rows")
    }
}
