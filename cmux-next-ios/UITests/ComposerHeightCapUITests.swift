import XCTest

/// Leo, 2026-11-23: "and composer growth in terminal view on ios is most certainly too high.
/// [...] adding attachments shouldn then expand the [...] composer EVEN TALLER... this goes for
/// the gui chat too... simply have it within the top part of the composer. the inner area grows
/// at the top. no shift, nothing."
///
/// The app drives its own composer under the DEBUG `-cmux-mobile-composer-proof`
/// (`ComposerProof`) and reports on `composer.proof.<screen>`:
/// - the card's height at 1, 5 and 20 lines with 0, 2 and 5 attachments, keyboard down and up,
///   and its share of the space above the keyboard;
/// - the frames the page's rows moved after adding or removing 1, 2 and 5 attachments.
/// After: the cap holds every combination and no row moves. `-cmux-mobile-composer-legacy`
/// runs the composer as before (14 terminal lines, a strip stacked on top) for the before row:
/// there the rows move and the tallest terminal composer passes the cap.
/// Each test attaches its readings (`composer-proof-*`) and a screenshot.
@MainActor
final class ComposerHeightCapUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testTerminalCapAndZeroShift() throws {
        let readings = try proof(screen: "terminal", demo: "ws-terminal-idle")
        assertAfter(readings, screen: "terminal")
    }

    func testChatCapAndZeroShift() throws {
        let readings = try proof(screen: "chat", demo: "kbd-chat")
        assertAfter(readings, screen: "chat")
    }

    /// The before row, same probe: the strip moves the rows and the terminal's 14 lines pass the cap.
    func testTerminalBeforeShiftsAndGrows() throws {
        let readings = try proof(screen: "terminal", demo: "ws-terminal-idle", extra: ["-cmux-mobile-composer-legacy"])
        let moved = readings.shifts.filter { $0.frames > 0 }
        XCTAssertFalse(moved.isEmpty, "before: adding an attachment moved the terminal rows")
        let tallest = try XCTUnwrap(readings.height(lines: 20, attachments: 0, keyboard: true))
        let five = try XCTUnwrap(readings.height(lines: 5, attachments: 0, keyboard: true))
        XCTAssertGreaterThan(tallest, five + 3 * 22, "before: 20 lines grow the terminal composer well past six")
    }

    func testChatBeforeShifts() throws {
        let readings = try proof(screen: "chat", demo: "kbd-chat", extra: ["-cmux-mobile-composer-legacy"])
        XCTAssertFalse(readings.shifts.filter { $0.frames > 0 }.isEmpty, "before: adding an attachment moved the transcript")
    }

    /// The cap's variants: 4, 6 and 8 lines, the tallest draft with the keyboard up, without
    /// and with two attachments (screenshots `cap-<n>-lines-*`).
    func testCapGallery() throws {
        var rows: [String] = []
        defer { attachText("composer-cap-gallery", rows.joined(separator: "\n")) }
        for screen in [("terminal", "ws-terminal-idle"), ("chat", "kbd-chat")] {
            for cap in [4, 6, 8] {
                let readings = try proof(screen: screen.0, demo: screen.1, name: "cap-\(cap)-lines-\(screen.0)",
                                         extra: ["-cmux-mobile-composer-proof-gallery", "-cmux-mobile-composer-max-lines", "\(cap)"])
                rows += readings.lines.map { "\(screen.0) cap=\(cap) \($0)" }
            }
        }
    }

    /// Leo's 2026-11-23 shot: the chat composer with four attachment thumbnails over five lines,
    /// keyboard up, about a third of the screen above the keyboard. Stills before and after
    /// (`leo-shot-chat-*`, `leo-shot-terminal-*`). After: four attachments over five lines are no
    /// taller than five lines alone plus the strip, and no taller than the six-line cap.
    func testLeoShotCase() throws {
        var rows: [String] = []
        defer { attachText("composer-leo-shot", rows.joined(separator: "\n")) }
        for screen in [("chat", "kbd-chat"), ("terminal", "ws-terminal-idle")] {
            var cards: [String: Double] = [:]
            for (label, extra) in [("before", ["-cmux-mobile-composer-legacy"]), ("after", [])] {
                for attachments in [0, 4] {
                    let name = "leo-shot-\(screen.0)-\(label)-\(attachments)"
                    let readings = try proof(screen: screen.0, demo: screen.1, name: name,
                                             extra: ["-cmux-mobile-composer-proof-gallery", "-cmux-mobile-composer-proof-case",
                                                     "5", "\(attachments)"] + extra)
                    rows += readings.lines.map { "\(screen.0) \(label) \($0)" }
                    cards["\(label)-\(attachments)"] = readings.height(lines: 5, attachments: attachments, keyboard: true)
                    if label == "after" {
                        // The strip takes part of the field: the line being typed stays in view.
                        for h in readings.heights where h.keyboard {
                            XCTAssertEqual(h.caret, "in", "\(name): the caret line is hidden under the field's edge")
                        }
                    }
                }
            }
            if let before = cards["before-4"], let after = cards["after-4"], let plain = cards["after-0"] {
                XCTAssertLessThanOrEqual(after, plain + 68 + 4, "\(screen.0): the strip adds at most its own height")
                XCTAssertLessThanOrEqual(after, before + 1, "\(screen.0): Leo's case is no taller than before")
            } else {
                XCTFail("\(screen.0): no heights read for Leo's case")
            }
        }
    }

    // MARK: Readings

    struct Shift { var lines: Int; var adding: Bool; var attachments: Int; var frames: Int; var max: Double }
    struct Height { var lines: Int; var attachments: Int; var keyboard: Bool; var card: Double; var frac: Double; var caret: String }
    struct Readings {
        var lines: [String]
        var heights: [Height]
        var shifts: [Shift]
        func height(lines: Int, attachments: Int, keyboard: Bool) -> Double? {
            heights.first { $0.lines == lines && $0.attachments == attachments && $0.keyboard == keyboard }?.card
        }
    }

    private func assertAfter(_ readings: Readings, screen: String) {
        XCTAssertEqual(readings.shifts.count, 12, "\(screen): 1, 2 and 5 attachments added and removed at 1 and 20 lines")
        for shift in readings.shifts {
            XCTAssertEqual(shift.frames, 0, "\(screen): \(shift.adding ? "adding" : "removing") \(shift.attachments) attachment(s) at \(shift.lines) line(s) moved the rows \(shift.max) pt")
        }
        for keyboard in [false, true] {
            guard let one = readings.height(lines: 5, attachments: 0, keyboard: keyboard),
                  let capped = readings.height(lines: 20, attachments: 0, keyboard: keyboard) else {
                XCTFail("\(screen): no heights read")
                return
            }
            // The card's one-line layout is a shorter row (the controls sit beside the field), so the
            // cap is read from five lines: the sixth, 22 pt, is the last the card grows.
            XCTAssertLessThanOrEqual(capped - one, 22 + 4, "\(screen): 20 lines stop at the six-line cap")
            for lines in [1, 5, 20] {
                for attachments in [2, 5] {
                    guard let height = readings.height(lines: lines, attachments: attachments, keyboard: keyboard) else { continue }
                    // Strip and text share the cap: attachments never take the card past it.
                    XCTAssertLessThanOrEqual(height, capped + 4, "\(screen): \(attachments) attachments at \(lines) lines stay within the cap")
                }
            }
            if let full = readings.height(lines: 20, attachments: 5, keyboard: keyboard) {
                XCTAssertEqual(full, capped, accuracy: 4, "\(screen): at the cap, attachments make the composer no taller")
            }
        }
    }

    private func proof(screen: String, demo: String, name: String? = nil, extra: [String] = []) throws -> Readings {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo, "-cmux-mobile-composer-proof"] + extra
        app.launch()
        defer { app.terminate() }
        let label = name ?? "\(screen)\(extra.contains("-cmux-mobile-composer-legacy") ? "-before" : "-after")"
        let probe = app.descendants(matching: .any)["composer.proof.\(screen)"]
        XCTAssertTrue(probe.waitForExistence(timeout: 60), "\(label): the proof started\n\(app.debugDescription)")
        let done = NSPredicate(format: "value BEGINSWITH 'done'")
        let finished = XCTWaiter().wait(for: [expectation(for: done, evaluatedWith: probe)], timeout: 180) == .completed
        let value = (probe.value as? String) ?? ""
        attachText("composer-proof-\(label)", value)
        attachScreenshot(app, label)
        XCTAssertTrue(finished, "\(label): the proof finished: \(value)")
        return parse(value)
    }

    private func parse(_ value: String) -> Readings {
        var heights: [Height] = []
        var shifts: [Shift] = []
        let lines = value.split(separator: "\n").map(String.init).filter { $0 != "done" && $0 != "running" }
        for line in lines {
            var fields: [String: String] = [:]
            for part in line.split(separator: " ") where part.contains("=") {
                let pair = part.split(separator: "=", maxSplits: 1)
                fields[String(pair[0])] = String(pair[1])
            }
            if line.hasPrefix("h ") {
                heights.append(Height(lines: Int(fields["L"] ?? "") ?? 0, attachments: Int(fields["A"] ?? "") ?? 0,
                                      keyboard: fields["kb"] == "up", card: Double(fields["card"] ?? "") ?? 0,
                                      frac: Double(fields["frac"] ?? "") ?? 0, caret: fields["caret"] ?? "-"))
            } else if line.hasPrefix("shift ") {
                shifts.append(Shift(lines: Int(fields["L"] ?? "") ?? 0, adding: line.contains(" add "),
                                    attachments: Int(fields["A"] ?? "") ?? 0, frames: Int(fields["frames"] ?? "") ?? -1,
                                    max: Double(fields["max"] ?? "") ?? 0))
            }
        }
        return Readings(lines: lines, heights: heights, shifts: shifts)
    }

    private func attachText(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
