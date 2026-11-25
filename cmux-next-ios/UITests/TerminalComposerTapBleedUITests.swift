import XCTest

/// Leo, 2026-11-25: "When I tap the composer at certain points it treats it as if I also
/// simultaneously tapped one of the combo buttons which needs to be fixed".
///
/// A touch lands in exactly one control: taps along the composer card's top edge, under every
/// key of the row above it, and in the gap between them, never fire a key or the joystick, and
/// the composer keeps the focus. The app's DEBUG probe `terminal.keyBar.fired` counts every key
/// the row fires ("count:id") and every touch the joystick takes. Each draft the composer can
/// hold is tried: one line, nine lines and attachments (the card at its tallest), and empty.
final class TerminalComposerTapBleedUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testEmptyComposerEdgeTapsFireNoKey() {
        run(demo: "ws-terminal-idle", composer: nil, name: "empty")
    }

    @MainActor
    func testOneLineComposerEdgeTapsFireNoKey() {
        run(demo: "ws-terminal-composer", composer: "short", name: "short")
    }

    @MainActor
    func testNineLineComposerEdgeTapsFireNoKey() {
        run(demo: "ws-terminal-composer", composer: "long", name: "long")
    }

    @MainActor
    func testComposerWithAttachmentsEdgeTapsFireNoKey() {
        run(demo: "ws-terminal-composer", composer: nil, name: "attachments")
    }

    @MainActor
    private func run(demo: String, composer: String?, name: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        if let composer { app.launchEnvironment["CMUX_MOBILE_DEMO_COMPOSER"] = composer }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo]
        app.launch()
        defer { app.terminate() }

        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "no composer field")
        // A demo that fills the draft does it a moment after the page opens.
        if composer != nil {
            let filled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                ((field.value as? String) ?? "").count > 4
            }, object: nil)
            _ = XCTWaiter().wait(for: [filled], timeout: 10)
        }
        // Raise the keyboard and the key row with it (it shows only over the keyboard).
        field.tap()
        let keyboardKey = app.buttons["terminal.key.keyboard"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard")
        XCTAssertTrue(keyboardKey.waitForHittable(timeout: 5), "no key row over the keyboard")
        // The row's slot opens over 0.25 s and fades in 0.15 s; the card settles after it.
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in false }, object: nil)
        _ = XCTWaiter().wait(for: [settled], timeout: 1.5)

        let probe = app.descendants(matching: .any)["terminal.keyBar.fired"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "no key row probe (a DEBUG build?)")
        let card = app.descendants(matching: .any)["terminal.composer.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no composer card")
        let cardFrame = card.frame
        let rowFrame = keyboardKey.frame
        XCTAssertGreaterThan(cardFrame.height, 0)
        XCTAssertLessThan(rowFrame.maxY, cardFrame.minY, "the key row \(rowFrame) and the card \(cardFrame) overlap")

        // Every key drawn in the row now: its x range is where a stray hit would land.
        let keys = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'terminal.key.'"))
            .allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        let joystick = app.descendants(matching: .any)["Cursor joystick"].firstMatch
        var columns: [(String, CGFloat)] = keys.map { ($0.identifier, $0.frame.midX) }
        if joystick.exists { columns.append(("joystick", joystick.frame.midX)) }
        XCTAssertGreaterThan(columns.count, 4, "too few keys found: \(columns)")
        // The card's own buttons (+, Send) open a menu or send: tap beside them, not on them.
        let avoid = ["terminal.composer.attach", "terminal.composer.send", "terminal.composer.voice"]
            .map { app.buttons[$0] }.filter(\.exists).map { $0.frame.insetBy(dx: -6, dy: -6) }

        // The card's top edge, just inside it (1 to 8 pt), and the gap between the row and the
        // card: points that are the composer's or nobody's, never a key's.
        let gapMid = (rowFrame.maxY + cardFrame.minY) / 2
        let ys: [CGFloat] = [rowFrame.maxY + 1, gapMid, cardFrame.minY + 1, cardFrame.minY + 3,
                             cardFrame.minY + 6, cardFrame.minY + 10]
        var before = probe.value as? String ?? ""
        var bled: [String] = []
        var tapped = 0
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for (id, x) in columns {
            for y in ys where y < cardFrame.maxY {
                let point = CGPoint(x: x, y: y)
                guard !avoid.contains(where: { $0.contains(point) }) else { continue }
                origin.withOffset(CGVector(dx: point.x, dy: point.y)).tap()
                tapped += 1
                let after = probe.value as? String ?? ""
                if after != before {
                    bled.append("(\(Int(point.x)), \(Int(point.y))) under \(id): \(before) -> \(after)")
                    before = after
                }
            }
        }
        attach("\(name)-after-edge-taps")
        XCTAssertGreaterThan(tapped, 20, "too few taps landed")
        XCTAssertTrue(bled.isEmpty, "\(bled.count) of \(tapped) taps on the composer's edge fired a key "
            + "(row \(rowFrame), card \(cardFrame)):\n" + bled.joined(separator: "\n"))

        // The composer keeps (or takes) the focus: the keyboard still types into the field.
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard went down")
        let focused = (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
        XCTAssertTrue(focused, "the composer lost the focus")
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
