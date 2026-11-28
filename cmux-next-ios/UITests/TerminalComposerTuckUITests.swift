import XCTest

/// Leo, 2026-11-23: "better ways/heuristics of auto-tucking swathes of the coding harness tui and
/// the weird little action buttons above the composer is a worthwhile endeavour too."
///
/// A Codex-like session (`FakeCodexSession`: a rule, its `›` line, a `Working (Ns) · esc to
/// interrupt` row). With the composer focused, each variant of `ComposerTuck` tucks what it
/// names; the shipped one (`both`) tucks the key row and the harness's status rows, and both come
/// back when the person taps the terminal. Screenshots of the three variants are the gallery.
final class TerminalComposerTuckUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testComposerInUseTucksTheKeyRowAndTheHarnessStatusRows() {
        var numbers: [String] = []
        for variant in ["keys", "chrome", "both"] {
            XCUIDevice.shared.orientation = .portrait
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle",
                                    "-cmux-mobile-term-fake-codex", "-cmux-mobile-tuck-probe",
                                    "-cmuxMobileComposerTuck", variant]
            app.launch()

            let field = app.textViews["terminal.composer.field"]
            let probe = app.descendants(matching: .any)["terminal.tuckProbe"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 30))
            XCTAssertTrue(probe.waitForExistence(timeout: 10), "no tuck probe: this build does not tuck")
            // Let the reply stream for a moment: the live area is drawn.
            sleep(4) // test: the fake session's first lines and live area
            attach("\(variant)-1-composer-down")
            let resting = Probe(probe.value as? String ?? "")
            XCTAssertFalse(resting.inUse, "\(variant): \(resting.raw)")
            XCTAssertEqual(resting.tucked, 0, "\(variant): \(resting.raw)")

            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let focused = waitFor(probe) { $0.inUse && $0.chrome > 0 }
            attach("\(variant)-2-composer-focused")
            XCTAssertFalse(focused.prompt, "\(variant): \(focused.raw)")
            XCTAssertGreaterThanOrEqual(focused.chrome, 3, "\(variant): the rule, the › line and the status row. \(focused.raw)")
            switch variant {
            case "keys":
                XCTAssertFalse(focused.keys, "\(variant): \(focused.raw)")
                XCTAssertEqual(focused.tucked, 0, "\(variant): \(focused.raw)")
            case "chrome":
                XCTAssertTrue(focused.keys, "\(variant): \(focused.raw)")
                XCTAssertEqual(focused.tucked, focused.chrome, "\(variant): \(focused.raw)")
            default:
                XCTAssertFalse(focused.keys, "\(variant): \(focused.raw)")
                XCTAssertEqual(focused.tucked, focused.chrome, "\(variant): \(focused.raw)")
                XCTAssertFalse(app.buttons["terminal.key.keyboard"].isHittable, "the key row tucks while composing")
            }
            numbers.append("\(variant): chrome \(focused.chrome) rows, tucked \(focused.tucked), conversation \(focused.conversation) rows")

            if variant == "both" {
                // The person asks for the terminal: everything comes back.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
                let back = waitFor(probe) { !$0.inUse }
                attach("both-3-terminal-tapped")
                XCTAssertEqual(back.tucked, 0, back.raw)
            }
            app.terminate()
        }
        let note = XCTAttachment(string: numbers.joined(separator: "\n"))
        note.name = "tuck-numbers"
        note.lifetime = .keepAlways
        add(note)
    }

    /// The probe's `key=value` fields.
    private struct Probe {
        let raw: String
        var fields: [String: String] {
            Dictionary(raw.split(separator: " ").compactMap { part in
                let pair = part.split(separator: "=", maxSplits: 1)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            }, uniquingKeysWith: { $1 })
        }
        init(_ raw: String) { self.raw = raw }
        var inUse: Bool { fields["inUse"] == "true" }
        var prompt: Bool { fields["prompt"] == "true" }
        var keys: Bool { fields["keys"] == "true" }
        var chrome: Int { Int(fields["chrome"] ?? "") ?? 0 }
        var tucked: Int { Int(fields["tucked"] ?? "") ?? 0 }
        var conversation: Int { Int(fields["conversation"] ?? "") ?? 0 }
    }

    @MainActor
    private func waitFor(_ probe: XCUIElement, _ holds: (Probe) -> Bool) -> Probe {
        let deadline = Date().addingTimeInterval(8)
        var last = Probe(probe.value as? String ?? "")
        while !holds(last), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            last = Probe(probe.value as? String ?? "")
        }
        return last
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
