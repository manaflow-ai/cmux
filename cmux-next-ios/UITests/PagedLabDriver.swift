import XCTest

/// Drives the shared infinite-scroll list's lab (`-cmux-mobile-paged-lab`, verify/paged-list.md) for
/// `PagedListUITests` and `PagedListStressUITests`: launches it, scrolls it at a named speed, reads
/// its measurement line and keeps what a test measured (a `PAGEDLIST` console line, which the
/// `ios-pagedlist` bench reads, and an attachment of the same name).
@MainActor
struct PagedLabDriver {
    let app: XCUIApplication
    let test: XCTestCase

    /// How fast a test scrolls: `slow` is a held drag (no fling), `medium` a short fling, `fast`
    /// XCUITest's fast swipe.
    enum Speed: String, CaseIterable {
        case slow, medium, fast
    }

    static func launch(_ lab: String, extra: [String] = [], test: XCTestCase) -> PagedLabDriver {
        let app = XCUIApplication()
        app.launchArguments += ["-cmux-mobile-paged-lab", lab] + extra
        app.launch()
        return PagedLabDriver(app: app, test: test)
    }

    var list: XCUIElement { app.collectionViews["lab.list"] }

    func row(_ id: Int) -> XCUIElement { app.descendants(matching: .any)["lab.row.\(id)"] }

    /// The lab's measurement line, as JSON in its accessibility value.
    var reading: PagedLabReading { PagedLabReading(app.staticTexts["lab.hud"].value as? String ?? "") }

    /// One scroll gesture. `towardOlder` scrolls into the older pages (down a `.down` list, up an
    /// `.up` one); otherwise back toward the newest rows.
    func scroll(towardOlder: Bool, direction: String, speed: Speed) {
        // Content moves up (negative) to read further down the list.
        let contentUp = (direction == "down") == towardOlder
        switch speed {
        case .fast:
            if contentUp { list.swipeUp(velocity: .fast) } else { list.swipeDown(velocity: .fast) }
        case .medium:
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: contentUp ? 0.75 : 0.25))
            start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: 0, dy: contentUp ? -360 : 360)),
                        withVelocity: XCUIGestureVelocity(rawValue: 1500), thenHoldForDuration: 0)
        case .slow:
            drag(by: contentUp ? -300 : 300)
        }
    }

    /// A held drag of `dy` points (negative moves content up: toward the bottom of the list).
    func drag(by dy: CGFloat) {
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: dy < 0 ? 0.8 : 0.15))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)), withVelocity: .slow,
                    thenHoldForDuration: 0.3)
    }

    /// The top of every lab row on screen (a row partly under the bars counts), from one snapshot.
    func rowTops() -> [String: CGFloat] {
        guard let snapshot = try? list.snapshot() else { return [:] }
        var tops: [String: CGFloat] = [:]
        func walk(_ element: XCUIElementSnapshot) {
            if element.identifier.hasPrefix("lab.row."), !element.frame.isEmpty { tops[element.identifier] = element.frame.minY }
            element.children.forEach(walk)
        }
        walk(snapshot)
        return tops
    }

    /// The first lab row fully on screen inside the list, away from its edges (`nearFloor`: the
    /// lowest one above the bars under the list, which stays on screen when the rows ride the
    /// keyboard up).
    func visibleRow(nearFloor: Bool = false) -> XCUIElement {
        let frame = list.frame
        let bottom = min(frame.maxY, floor)
        if let snapshot = try? list.snapshot() {
            func rows(_ element: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
                (element.identifier.hasPrefix("lab.row.") ? [element] : []) + element.children.flatMap(rows)
            }
            let inView = rows(snapshot).filter { $0.frame.minY > frame.minY + 120 && $0.frame.maxY < bottom - (nearFloor ? 8 : 120) }
            let pick = nearFloor ? inView.max { $0.frame.maxY < $1.frame.maxY } : inView.first
            if let pick { return app.descendants(matching: .any)[pick.identifier] }
        }
        return app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'lab.row.'")).firstMatch
    }

    /// The list's bottom edge as drawn: the top of the lowest bar under it (the ops, the measurement
    /// line, the composer).
    var floor: CGFloat {
        [app.otherElements["lab.ops"], app.staticTexts["lab.hud"], app.textFields["lab.composer"]]
            .filter(\.exists).map(\.frame.minY).min() ?? list.frame.maxY
    }

    func waitFor(_ what: String, timeout: TimeInterval, _ condition: @escaping () -> Bool) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: timeout), .completed, "timed out waiting for \(what)")
    }

    /// Waits until the element's frame stops changing (three equal reads in a row), at most 3 s.
    func settle(_ element: XCUIElement) {
        var last = element.frame
        var still = 0
        let steady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let now = element.frame
            still = now == last ? still + 1 : 0
            last = now
            return still >= 2
        }, object: nil)
        _ = XCTWaiter.wait(for: [steady], timeout: 3)
    }

    /// A measurement: printed (the fleet step's console keeps it for the bench), and kept as a named
    /// attachment.
    func record(_ name: String, _ json: String) {
        print("PAGEDLIST \(name) \(json)")
        let note = XCTAttachment(string: json)
        note.name = "PAGEDLIST-\(name)"
        note.lifetime = .keepAlways
        test.add(note)
    }

    func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        test.add(shot)
    }
}

/// The lab's measurement line (`PagedLabHUD.json`): read leniently, so a field a test does not use
/// can come or go.
struct PagedLabReading {
    let json: String
    private let values: [String: Any]

    init(_ json: String) {
        self.json = json.isEmpty ? "{}" : json
        values = (json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private func number(_ key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }

    var edge: String { values["edge"] as? String ?? "" }
    var newer: String { values["newer"] as? String ?? "" }
    var rows: Int { Int(number("rows")) }
    var landings: Int { Int(number("landings")) }
    /// The worst move of the row being read when a page landed (pt).
    var maxShift: Double { number("maxShift") }
    /// The worst per-frame move of the row being read that the scroll does not explain (pt).
    var frameShift: Double { number("frameShift") }
    /// The rows around the eye line (the neighbour measure), the largest drawn move beyond the scroll.
    var neighbourShift: Double { number("neighbourShift") }
    var neighbourShifted: Int { Int(number("neighbourShifted")) }
    var samples: Int { Int(number("samples")) }
    var shiftedFrames: Int { Int(number("shiftedFrames")) }
    var frames: Int { Int(number("frames")) }
    var hitches: Int { Int(number("hitches")) }
    var dropped: Int { Int(number("dropped")) }
    var worstMs: Double { number("worstMs") }
    var hitchMsPerS: Double { number("hitchMsPerS") }
    var changes: Int { Int(number("changes")) }
    var flushes: Int { Int(number("flushes")) }
    var inMemory: Int { Int(number("inMemory")) }
    var total: Int { Int(number("total")) }
    var onDisk: Int { Int(number("onDisk")) }
    var diskBytes: Int { Int(number("diskBytes")) }
    var slides: Int { Int(number("slides")) }
    var slideFrames: Int { Int(number("slideFrames")) }
    var held: Int { Int(number("held")) }
}
