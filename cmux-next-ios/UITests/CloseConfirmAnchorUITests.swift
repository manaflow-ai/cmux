import XCTest

/// The Workspaces list's close confirmations point at the row or group header
/// whose menu (or swipe) asked for them: Close Other Workspaces, Close
/// Workspaces Above / Below and Close All Workspaces from a row's Close folder,
/// and Close (the swipe). Before 2026-11-11 the bulk closes opened detached
/// (from the list's top-left corner), because only the single Close moved the
/// popover's anchor to its row; and near the list's bottom every one of them,
/// the single Close too, slid up over the row it named. A group header's
/// Close All in Group, Close Other Groups and Delete Group take the same path,
/// but mock data has no Mac groups, so they are not reached here.
///
/// Each check opens the confirmation and requires its popover (title down to
/// its destructive button) to sit right above or right below its source, as a
/// popover whose arrow touches the source does. Runs on mock data.
final class CloseConfirmAnchorUITests: XCTestCase {
    typealias A = CloseConfirmAnchor

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testCloseOtherPointsAtTopMiddleAndBottomRows() {
        for position in A.Position.allCases {
            let app = A.launch()
            let row = A.row(app, position)
            XCTAssertNotNil(row, "no \(position) row\n\(app.debugDescription)")
            guard let row else { app.terminate(); continue }
            XCTAssertNil(A.openRowClose(app, row: row, kind: "Close Other Workspaces"), "\(position) row")
            A.assertPoints(app, at: row, button: "Close Workspaces", what: "Close Other Workspaces from the \(position) row", test: self)
            app.terminate()
        }
    }

    @MainActor
    func testAboveBelowAllAndSwipeClosePointAtTheirRows() {
        let cases: [(A.Position, String, String)] = [
            (.bottom, "Close Workspaces Above", "Close Workspaces"),
            (.top, "Close Workspaces Below", "Close Workspaces"),
            (.middle, "Close All Workspaces", "Close Workspaces"),
        ]
        for (position, kind, button) in cases {
            let app = A.launch()
            guard let row = A.row(app, position) else { XCTFail("no \(position) row"); app.terminate(); continue }
            XCTAssertNil(A.openRowClose(app, row: row, kind: kind), kind)
            A.assertPoints(app, at: row, button: button, what: "\(kind) from the \(position) row", test: self)
            app.terminate()
        }
        let app = A.launch()
        if let row = A.row(app, .bottom) {
            XCTAssertNil(A.openSwipeClose(app, row: row), "swipe Close")
            A.assertPoints(app, at: row, button: "Close Workspace", what: "swipe Close from the bottom row", test: self)
        } else {
            XCTFail("no bottom row")
        }
        app.terminate()
    }
}

/// Reach and measure helpers, shared with the all-UI-states capture scenes.
enum CloseConfirmAnchor {
    enum Position: String, CaseIterable { case top, middle, bottom }

    /// The Mac Studio's rows (mock data): the ones with Close folders.
    static let studioRows: Set<String> = [
        "ws-cmux", "ws-web", "ws-ios", "ws-infra", "ws-ghostty", "ws-design", "ws-blog", "ws-release",
    ]

    @MainActor
    static func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore", "-cmuxMobile.setupComplete", "YES"] + extra
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons["Manaflow"].tap() }
        _ = app.buttons["workspace.row.ws-cmux"].waitForExistence(timeout: 30)
        return app
    }

    /// The top, middle or bottom Mac Studio row wholly between the bars.
    @MainActor
    static func row(_ app: XCUIApplication, _ position: Position) -> XCUIElement? {
        let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 100
        let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY - 90
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace.row.ws-'")).allElementsBoundByIndex
            .filter { studioRows.contains(String($0.identifier.dropFirst("workspace.row.".count))) }
            .filter { $0.frame.minY >= top && $0.frame.maxY <= bottom && !$0.frame.isEmpty }
            .sorted { $0.frame.minY < $1.frame.minY }
        guard !rows.isEmpty else { return nil }
        switch position {
        case .top: return rows.first
        case .middle: return rows[rows.count / 2]
        case .bottom: return rows.last
        }
    }

    /// Long press the row, open its Close folder and pick `kind`.
    @MainActor
    static func openRowClose(_ app: XCUIApplication, row: XCUIElement, kind: String) -> String? {
        UIStateCaptureCase.steps([
            { UIStateCaptureCase.longPress(row, "\(row.identifier)") },
            { menuTap(app.buttons["Close"].firstMatch, "Close folder") },
            { menuTap(app.buttons[kind].firstMatch, kind) },
            { UIStateCaptureCase.wait(dialogTitle(app), "confirmation title", timeout: 8) },
        ])
    }

    /// The trailing swipe's Close.
    @MainActor
    static func openSwipeClose(_ app: XCUIApplication, row: XCUIElement) -> String? {
        UIStateCaptureCase.steps([
            { UIStateCaptureCase.swipeLeft(row, "\(row.identifier)") },
            { UIStateCaptureCase.tap(app.buttons["Close"].firstMatch, "Close swipe action") },
            { UIStateCaptureCase.wait(dialogTitle(app), "confirmation title", timeout: 8) },
        ])
    }

    /// Taps a context menu item. An element tap (not a coordinate one) lets
    /// XCTest scroll a long menu to a listed item. At accessibility sizes the
    /// menu lists only what fits, so the drag goes inside the menu, which sits
    /// in the screen's upper part over the row (a drag beside a short menu
    /// would dismiss it).
    @MainActor
    static func menuTap(_ element: XCUIElement, _ what: String) -> String? {
        var found = element.waitForExistence(timeout: 4)
        for _ in 0..<5 where !found {
            let app = XCUIApplication()
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            found = element.waitForExistence(timeout: 2)
        }
        guard found else { return "no \(what)" }
        element.tap()
        return nil
    }

    /// "Close 3 workspaces?", "Close “cmux.com”?" or "Delete “beta”?".
    @MainActor
    static func dialogTitle(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "(label BEGINSWITH 'Close ' OR label BEGINSWITH 'Delete ') AND label ENDSWITH '?'")).firstMatch
    }

    /// The popover as the test sees it: from its title down to its destructive button.
    @MainActor
    static func popover(_ app: XCUIApplication, button: String) -> CGRect? {
        let title = dialogTitle(app)
        let action = app.buttons.matching(NSPredicate(format: "label == %@", button)).allElementsBoundByIndex
            .filter { $0.frame.minY >= title.frame.minY }.min { $0.frame.minY < $1.frame.minY }
        guard title.exists, let action else { return nil }
        return title.frame.union(action.frame)
    }

    /// How far the popover's content sits from its source: the gap between the
    /// source and the content's near edge, above or below; infinity when the
    /// content overlaps the source. A popover whose arrow touches its source
    /// keeps its content `minGap...maxGap` away (the arrow and the popover's
    /// inset). Less means it slid over the source.
    static func gap(_ popover: CGRect, from source: CGRect) -> CGFloat {
        let below = popover.minY - source.maxY
        let above = source.minY - popover.maxY
        return [below, above].filter { $0 >= 0 }.min() ?? .infinity
    }

    static let minGap: CGFloat = 12
    static let maxGap: CGFloat = 80

    @MainActor
    static func assertPoints(_ app: XCUIApplication, at source: XCUIElement, button: String, what: String, test: XCTestCase,
                             file: StaticString = #filePath, line: UInt = #line) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = what
        shot.lifetime = .keepAlways
        test.add(shot)
        guard let rect = popover(app, button: button) else {
            XCTFail("\(what): no popover with \(button)\n\(app.debugDescription)", file: file, line: line)
            return
        }
        let distance = gap(rect, from: source.frame)
        print("CLOSE-ANCHOR \(what): source \(source.frame) popover \(rect) gap \(distance)")
        XCTAssertTrue((minGap...maxGap).contains(distance),
                      "\(what): the popover \(rect) is \(distance) pt from its source \(source.frame), want \(minGap)...\(maxGap)",
                      file: file, line: line)
    }
}
