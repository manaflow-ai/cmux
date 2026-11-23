import XCTest

/// The offline link-drop rig (`LinkDropRig`, DEBUG, mock mode): a Mac's link drops and comes back
/// on a script, no agent and no Mac. Per chip surface, idle and under load, this measures the
/// wall-clock time from each drop to its connection chip, and counts layout shifts: any row on
/// screen that moved while nothing scrolled.
///
/// Leo (2026-11-22): "we should almost always be doing this. always. testing under duress. you
/// should also be able to simulate duress "offline" aka without a true agent thing". The chip
/// waits the 10 s quiet bound from the drop (Leo, 2026-11-21: "stop layout shifting").
///
/// Each test prints one line per drop, for the PR table and the sweep:
/// `LINKDROP surface=home load=idle cycle=1 time_to_chip_ms=10140 resolution_ms=80
/// chip_gone_ms=310 shifts=0 samples=212`.
final class LinkDropChipUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testHomeChipIdle() throws { try measure(surface: "home", rows: "home.row.", load: false) }
    @MainActor func testHomeChipUnderLoad() throws { try measure(surface: "home", rows: "home.row.", load: true) }
    @MainActor func testWorkspacesChipIdle() throws { try measure(surface: "workspaces", rows: "workspace.row.", load: false) }
    @MainActor func testWorkspacesChipUnderLoad() throws { try measure(surface: "workspaces", rows: "workspace.row.", load: true) }

    /// One sample of the screen, from a single accessibility snapshot.
    private struct Sample {
        let at: Date
        let chip: Bool
        let rows: [String: CGRect]
        let marker: String?
    }

    @MainActor
    private func measure(surface: String, rows prefix: String, load: Bool) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore",
                                "-cmux-mobile-link-drop", surface, "-cmux-mobile-link-drop-load", load ? "1" : "0"]
        app.launch()
        defer { app.terminate() }
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons.element(boundBy: 0).tap() }
        let marker = app.descendants(matching: .any)["rig.linkdrop"]
        XCTAssertTrue(marker.waitForExistence(timeout: 30), "the link-drop rig runs\n\(app.debugDescription)")

        // Sample until the script ends (2 drops of 14 s, 5 s up around each: about 43 s).
        var samples: [Sample] = []
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let sample = try take(app, prefix: prefix)
            samples.append(sample)
            if sample.marker?.hasSuffix(" done") == true { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        let events = try XCTUnwrap(samples.last?.marker, "the rig's events")
        XCTAssertTrue(events.hasSuffix(" done"), "the rig finished in time: \(events)")
        attach(app, "\(surface)-\(load ? "load" : "idle")-end")
        let stamps = Self.stamps(events)
        let condition = load ? "load" : "idle"

        var cycle = 1
        while let down = stamps["down\(cycle)"], let back = stamps["back\(cycle)"] {
            let during = samples.filter { $0.at >= down && $0.at < back }
            let first = during.firstIndex { $0.chip }
            let shown = first.map { during[$0] }
            let before = first.flatMap { $0 > 0 ? during[$0 - 1] : nil }
            let timeToChip = shown.map { $0.at.timeIntervalSince(down) * 1000 }
            // The chip showed somewhere between the sample before and this one.
            var resolution: Double?
            if let shown, let before { resolution = shown.at.timeIntervalSince(before.at) * 1000 }
            let gone = samples.first { $0.at >= back && !$0.chip }.map { $0.at.timeIntervalSince(back) * 1000 }
            // Shifts: from 1 s before the drop to 3 s after the return, consecutive samples in
            // which a row on screen in both moved (nothing scrolls in this test).
            let window = samples.filter { $0.at >= down.addingTimeInterval(-1) && $0.at < back.addingTimeInterval(3) }
            var shifts: [String] = []
            for (previous, next) in zip(window, window.dropFirst()) {
                for (id, frame) in next.rows {
                    guard let old = previous.rows[id] else { continue }
                    if abs(old.minY - frame.minY) > 0.5 || abs(old.minX - frame.minX) > 0.5 || abs(old.height - frame.height) > 0.5 {
                        shifts.append(String(format: "%@ %.0f->%.0f at %.0f ms", id, old.minY, frame.minY, next.at.timeIntervalSince(down) * 1000))
                        break
                    }
                }
            }
            let line = String(format: "LINKDROP surface=%@ load=%@ cycle=%d time_to_chip_ms=%@ resolution_ms=%@ chip_gone_ms=%@ shifts=%d samples=%d",
                              surface, condition, cycle, timeToChip.map { String(format: "%.0f", $0) } ?? "none",
                              resolution.map { String(format: "%.0f", $0) } ?? "none",
                              gone.map { String(format: "%.0f", $0) } ?? "none", shifts.count, window.count)
            print(line)
            note("linkdrop-\(surface)-\(condition)-\(cycle)", line + (shifts.isEmpty ? "" : "\n" + shifts.joined(separator: "\n")))

            XCTAssertTrue(window.contains { !$0.rows.isEmpty }, "rows were on screen to watch: \(line)")
            let chipTime = try XCTUnwrap(timeToChip, "\(surface) \(condition) cycle \(cycle): no chip during a \(back.timeIntervalSince(down)) s drop\n\(line)")
            // Nothing before the 10 s bound (a sample can lag the chip, never lead it).
            XCTAssertGreaterThanOrEqual(chipTime, 9_900, "the chip showed before the bound: \(line)")
            XCTAssertTrue(shifts.isEmpty, "rows moved as the chip came and went: \(line)\n\(shifts.joined(separator: "\n"))")
            cycle += 1
        }
        XCTAssertGreaterThan(cycle, 1, "at least one drop and return: \(events)")
    }

    @MainActor
    private func take(_ app: XCUIApplication, prefix: String) throws -> Sample {
        let root = try app.snapshot()
        let at = Date()
        var chip = false
        var rows: [String: CGRect] = [:]
        var marker: String?
        func walk(_ element: XCUIElementSnapshot) {
            let id = element.identifier
            if id.hasPrefix("connection.chip") || id == "home.note.updating" { chip = true }
            if id.hasPrefix(prefix), !element.frame.isEmpty { rows[id] = element.frame }
            if id == "rig.linkdrop" { marker = element.value as? String }
            element.children.forEach(walk)
        }
        walk(root)
        return Sample(at: at, chip: chip, rows: rows, marker: marker)
    }

    /// `load=0 up down1=1795… back1=1795… done` to its stamps.
    private static func stamps(_ events: String) -> [String: Date] {
        var out: [String: Date] = [:]
        for part in events.split(separator: " ") {
            let pair = part.split(separator: "=")
            guard pair.count == 2, let ms = Double(pair[1]), pair[0] != "load" else { continue }
            out[String(pair[0])] = Date(timeIntervalSince1970: ms / 1000)
        }
        return out
    }

    @MainActor
    private func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
