import UIKit
import XCTest

/// The Feed parks one spare row cell off screen before its first scroll (FeedListController
/// `spare`). Parked, it is invisible to everything: the screen does not change when it leaves its
/// park, and the UI test's cells and the accessibility elements are the list's rows, each once,
/// none beside the list.
final class FeedParkedSpareUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The checks against what the list shows: the screen changing when the spare leaves its park
    /// (it was drawn), an event listed twice, or an element beside the list. Returns the problems found (empty: the parked spare is invisible).
    @MainActor
    private func problems(mutant: Bool) -> [String] {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "60"
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS_LIVE"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "feed"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0"
        if mutant { app.launchEnvironment["CMUX_MOBILE_FEED_SPARE_MUTANT"] = "visible" }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }
        // No query until the first screenshot. Every XCUITest query walks the accessibility tree,
        // and a table's walk asks for a cell for every row past the screen: the first new cell it
        // needs takes the parked spare (spare-ui-2 0be1c442: the mutant drew over the first row,
        // then a team-chooser poll took it, before any check ran). So the Feed sits still with
        // nothing asking for 12 s (it shows its rows and builds the spare after 0.5 s still),
        // the screen is shot as it is, then the walk takes the spare and the screen is shot again.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the Feed sits still, unqueried")], timeout: 12)
        let shotParked = XCUIScreen.main.screenshot()
        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 40), "the Feed's table\n\(app.debugDescription)")
        let rows = list.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "the events\n\(app.debugDescription)")
        _ = rows.allElementsBoundByIndex.count
        let walked = XCUIScreen.main.screenshot()
        for (name, shot) in [("parked", shotParked), ("walked", walked)] {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "feed-spare-\(mutant ? "mutant" : "normal")-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // The list's DEBUG value is its trace: the spare must have been made before the first
        // screenshot and taken (if at all) only by the walk after it, seconds later. A take right
        // after the build would mean the first screenshot showed no spare, and proves nothing.
        let trace = list.value as? String ?? ""
        let at: (String) -> Double? = { mark in
            trace.split(separator: "\n").first { $0.contains(mark) }.flatMap { Double($0.split(separator: " ").first ?? "") }
        }
        let note = XCTAttachment(string: trace)
        note.name = "feed-spare-\(mutant ? "mutant" : "normal")-trace"
        note.lifetime = .keepAlways
        add(note)
        guard let made = at("spare made") else {
            XCTFail("no spare was built while the Feed was still; list trace:\n\(trace)")
            return ["no spare was built"]
        }
        if let taken = at("spare taken"), taken - made < 3 {
            XCTFail("the spare was taken \(taken - made) s after it was made, before the first screenshot; trace:\n\(trace)")
            return ["the spare was taken before the first screenshot"]
        }
        var found: [String] = []
        // What a person sees, where a parked spare would draw: the mutant's holder sits at
        // y 200 pt over the rows (FeedCollection `buildSpare`), so only that band is compared,
        // 200-560 pt, inside the card it draws. The rest of the screen (navigation bar, tab bar,
        // any row a spinner or a relative time could change) is left out, and the fixture runs
        // with no live stream, so a normal run reads near 0%.
        let width = app.windows.firstMatch.frame.width
        if width > 0, let share = Self.share(shotParked.image, walked.image, band: 200...560, widthPoints: width) {
            let reading = XCTAttachment(string: String(format: "band 200-560 pt differs by %.3f%%", share * 100))
            reading.name = "feed-spare-\(mutant ? "mutant" : "normal")-share"
            reading.lifetime = .keepAlways
            add(reading)
            shares.append(share)
            if share > 0.02 { found.append(String(format: "the band changed by %.1f%% when the spare left its park (it was drawn)", share * 100)) }
        } else {
            found.append("the screenshots could not be compared")
        }
        // A table's accessibility lists its rows past the screen too (at their row frames, inside
        // the list's width): a parked spare would be a second copy of a row's identifier, or an
        // element beside the list (its holder sits off the window to the left).
        let frame = list.frame
        var seen: Set<String> = []
        for cell in rows.allElementsBoundByIndex where !seen.insert(cell.identifier).inserted {
            found.append("\(cell.identifier) is listed twice (a parked copy)")
        }
        let elements = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.stress-'"))
        var ids: [String: Int] = [:]
        for element in elements.allElementsBoundByIndex {
            ids[element.identifier, default: 0] += 1
            if element.frame.minX < frame.minX - 0.5 || element.frame.maxX > frame.maxX + 0.5 {
                found.append("\(element.identifier) at \(element.frame) is beside the list \(frame)")
            }
        }
        for (id, count) in ids where count > 1 { found.append("\(id) is \(count) accessibility elements") }
        // The parked spare's own identifier: never an element.
        let parked = app.descendants(matching: .any).matching(identifier: "feed.spare.parked")
        if parked.count > 0 { found.append("the parked spare is \(parked.count) accessibility element(s) at \(parked.firstMatch.frame)") }
        // Two row elements on top of each other (a spare over a row).
        let frames = elements.allElementsBoundByIndex.map { ($0.identifier, $0.frame) }
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] {
                let overlap = a.1.intersection(b.1)
                if !overlap.isNull, overlap.height > 1, overlap.width > 1 { found.append("\(a.0) and \(b.0) overlap by \(overlap.height) pt") }
            }
        }
        if elements.count != seen.count { found.append("accessibility elements \(elements.count) vs the list's rows \(seen.count)") }
        return found
    }

    /// The band's readings, one per launch (each attached as `feed-spare-*-share`).
    private var shares: [Double] = []

    /// The share of pixels in `band` (points from the top) that differ between `a` and `b`.
    @MainActor
    static func share(_ a: UIImage, _ b: UIImage, band: ClosedRange<CGFloat>, widthPoints: CGFloat) -> Double? {
        guard let first = AgentCLIHybridPixelDiffUITests.pixels(a), let second = AgentCLIHybridPixelDiffUITests.pixels(b),
              first.width == second.width, first.height == second.height else { return nil }
        let scale = CGFloat(first.width) / widthPoints
        let top = max(0, Int(band.lowerBound * scale)), bottom = min(first.height, Int(band.upperBound * scale))
        guard bottom > top else { return nil }
        var differing = 0
        for y in top..<bottom {
            for x in 0..<first.width {
                let i = (y * first.width + x) * 4
                let delta = max(abs(Int(first.bytes[i]) - Int(second.bytes[i])),
                                abs(Int(first.bytes[i + 1]) - Int(second.bytes[i + 1])),
                                abs(Int(first.bytes[i + 2]) - Int(second.bytes[i + 2])))
                if delta > AgentCLIHybridPixelDiffUITests.channelTolerance { differing += 1 }
            }
        }
        return Double(differing) / Double(first.width * (bottom - top))
    }

    /// Three launches, each under 2% in the band: one quiet reading could be luck.
    @MainActor
    func testTheParkedSpareIsNotACellOrAnAccessibilityElement() {
        for run in 1...3 {
            let found = problems(mutant: false)
            XCTAssertTrue(found.isEmpty, "run \(run): " + found.joined(separator: "\n"))
        }
        XCTAssertEqual(shares.count, 3, "a run gave no reading")
        let all = XCTAttachment(string: shares.map { String(format: "%.3f%%", $0 * 100) }.joined(separator: ", "))
        all.name = "feed-spare-normal-shares"
        all.lifetime = .keepAlways
        add(all)
    }

    /// The red for the test above: a spare parked on screen over the rows, readable (DEBUG
    /// `CMUX_MOBILE_FEED_SPARE_MUTANT=visible`). The same checks must find it.
    @MainActor
    func testAVisibleParkedSpareIsCaught() {
        let found = problems(mutant: true)
        XCTAssertFalse(found.isEmpty, "the checks did not catch a spare parked visibly in the list")
        XCTAssertFalse(found == ["no spare was built"], "the mutant built no spare, so it proves nothing")
    }
}
