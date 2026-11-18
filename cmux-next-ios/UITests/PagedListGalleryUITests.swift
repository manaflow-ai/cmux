import XCTest

/// Every state of the shared infinite-scroll list, in light and dark, as named screenshots for the
/// review report (verify/paged-list.md): the first page loading, failed and empty; rows down and up;
/// the edge loading, failed and at the end; pull to refresh; a swipe action open; the keyboard with the
/// composer; the newest-rows pill; accessibility text size; and Agent Chats' states. The lab's
/// measurement line and test buttons are hidden (`-cmux-mobile-paged-lab-clean`). Each shot is
/// `gallery-<state>-<look>`; a state that did not show is recorded as missing, not failed, so one
/// slow state does not hide the others.
final class PagedListGalleryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor func testGalleryLight() { gallery("light") }
    @MainActor func testGalleryDark() { gallery("dark") }

    @MainActor
    private func gallery(_ look: String) {
        var missing: [String] = []
        func open(_ lab: String, _ extra: [String] = []) -> PagedLabDriver {
            PagedLabDriver.launch(lab, extra: ["-cmux-mobile-gallery-appearance", look, "-cmux-mobile-paged-lab-clean"] + extra, test: self)
        }
        func shot(_ lab: PagedLabDriver, _ state: String, when element: XCUIElement, timeout: TimeInterval = 10) {
            if element.waitForExistence(timeout: timeout) {
                lab.settle(element)
                lab.attach("gallery-\(state)-\(look)")
            } else {
                missing.append(state)
            }
        }
        func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

        // The first page: loading, failed, empty.
        var lab = open("down:slow")
        shot(lab, "first-loading", when: any(lab.app, "lab.list.loading"), timeout: 5)
        lab.app.terminate()
        lab = open("down:firstfail")
        shot(lab, "first-failed", when: any(lab.app, "lab.list.failed"))
        lab.app.terminate()
        for direction in ["down", "up"] {
            lab = open("\(direction):empty")
            shot(lab, "empty-\(direction)", when: any(lab.app, "lab.list.empty"))
            lab.app.terminate()
        }

        // Rows, both directions (`.up` opens at its newest row, over the composer).
        lab = open("down:normal")
        shot(lab, "rows-down", when: lab.row(0))
        // Pull to refresh, caught while the indicator shows.
        let start = lab.list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 260)), withVelocity: .slow, thenHoldForDuration: 0.6)
        lab.attach("gallery-pull-to-refresh-\(look)")
        lab.settle(lab.row(0))
        // A swipe action open.
        lab.row(2).swipeLeft()
        shot(lab, "swipe-open", when: lab.app.buttons["Archive"], timeout: 3)
        lab.app.terminate()
        lab = open("up:normal")
        shot(lab, "rows-up", when: lab.row(0))
        // The keyboard with the composer: the rows ride up with it.
        let composer = lab.app.textFields["lab.composer"]
        composer.tap()
        shot(lab, "keyboard-up", when: lab.app.keyboards.firstMatch, timeout: 5)
        lab.app.terminate()

        // The edge: loading (6 s pages), failed with Try Again, the end with its label.
        for direction in ["down", "up"] {
            // The second page never answers here (`stall`): fling to the edge and shoot its spinner.
            // (With pages that do answer, the read ahead keeps the edge as far ahead as the flings
            // go.) The edge draws the same spinner while more pages exist and while one is read
            // (`.more` and `.loading`, one view, so the state change moves nothing): either is this state.
            lab = open("\(direction):stall")
            let loading = lab.app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier IN %@", ["lab.list.edge.loading", "lab.list.edge.more"])).firstMatch
            if lab.row(0).waitForExistence(timeout: 15) {
                for _ in 0..<16 where !loading.exists {
                    if direction == "down" { lab.list.swipeUp(velocity: .fast) } else { lab.list.swipeDown(velocity: .fast) }
                }
            }
            if loading.exists {
                lab.settle(loading)
                lab.attach("gallery-edge-loading-\(direction)-\(look)")
            } else {
                missing.append("edge-loading-\(direction)")
            }
            lab.app.terminate()
        }
        lab = open("down:morefail")
        if lab.row(0).waitForExistence(timeout: 10) {
            let failed = any(lab.app, "lab.list.edge.failed")
            for _ in 0..<12 where !(failed.exists && failed.isHittable) { lab.list.swipeUp(velocity: .fast) }
            shot(lab, "edge-failed", when: failed)
        } else {
            missing.append("edge-failed")
        }
        lab.app.terminate()
        for direction in ["down", "up"] {
            lab = open("\(direction):end")
            if lab.row(0).waitForExistence(timeout: 10) {
                let end = any(lab.app, "lab.list.edge.end")
                for _ in 0..<10 where !(end.exists && end.isHittable) {
                    if direction == "down" { lab.list.swipeUp(velocity: .fast) } else { lab.list.swipeDown(velocity: .fast) }
                }
                shot(lab, "end-\(direction)", when: end)
            } else {
                missing.append("end-\(direction)")
            }
            lab.app.terminate()
        }

        // The newest-rows pill: away from the newest end while live rows arrive (one every 1.5 s).
        lab = open("up:live")
        if lab.row(0).waitForExistence(timeout: 10) {
            for _ in 0..<4 { lab.drag(by: 420) }
            let pill = lab.app.buttons["pagedList.newest"]
            lab.waitFor("two arrivals", timeout: 8) { pill.exists && pill.label != "Newest" && pill.label != "1 new" }
            shot(lab, "newest-pill", when: pill, timeout: 2)
        } else {
            missing.append("newest-pill")
        }
        lab.app.terminate()

        // Accessibility text size, both directions.
        for direction in ["down", "up"] {
            lab = open("\(direction):normal", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
            shot(lab, "ax-xl-\(direction)", when: lab.row(0))
            lab.app.terminate()
        }

        // Agent Chats on the list: rows, the edge loading and failed, empty.
        lab = open("agentchats:pages")
        shot(lab, "agentchats-rows", when: any(lab.app, "agentChats.row.chat-0"))
        lab.app.terminate()
        lab = open("agentchats:slow")
        if any(lab.app, "agentChats.row.chat-0").waitForExistence(timeout: 10) {
            let loading = any(lab.app, "agentChats.list.edge.loading")
            for _ in 0..<4 where !loading.exists { lab.app.collectionViews["agentChats.list"].swipeUp(velocity: .fast) }
            shot(lab, "agentchats-edge-loading", when: loading, timeout: 3)
        } else {
            missing.append("agentchats-edge-loading")
        }
        lab.app.terminate()
        lab = open("agentchats:edgefail")
        if any(lab.app, "agentChats.row.chat-0").waitForExistence(timeout: 10) {
            let failed = any(lab.app, "agentChats.list.edge.failed")
            for _ in 0..<12 where !failed.exists { lab.app.collectionViews["agentChats.list"].swipeUp(velocity: .fast) }
            shot(lab, "agentchats-edge-failed", when: failed)
        } else {
            missing.append("agentchats-edge-failed")
        }
        lab.app.terminate()
        lab = open("agentchats:empty")
        shot(lab, "agentchats-empty", when: any(lab.app, "agentChats.list.empty"))
        lab.app.terminate()

        lab.record("gallery-\(look)", #"{"look":"\#(look)","missing":[\#(missing.map { "\"\($0)\"" }.joined(separator: ","))]}"#)
        XCTAssertTrue(missing.isEmpty, "states that did not show (\(look)): \(missing.joined(separator: ", "))")
    }
}
