import XCTest

/// The Workspaces list's close confirmations point at the row or group header
/// whose menu (or swipe) asked for them: Close Other Workspaces, Close
/// Workspaces Above / Below and Close All Workspaces from a row's Close folder,
/// Close (the swipe), and Close All in Group, Close Other Groups and Delete
/// Group from a group header. Before 2026-11-11 the bulk closes and Delete
/// Group opened detached (from the list's top-left corner, or as a sheet),
/// because only the single Close moved the popover's anchor to its row.
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

    @MainActor
    func testGroupHeaderClosesPointAtTheHeader() {
        for (item, button) in [("Close All in Group", "Close Workspace"), ("Close Other Groups", "Close Workspace"),
                               ("Delete Group", "Delete Group")] {
            let app = A.launch()
            XCTAssertNil(A.makeTwoGroups(app), "groups for \(item)\n\(app.debugDescription)")
            guard let header = A.header(app, A.secondGroup) else { XCTFail("no group header"); app.terminate(); continue }
            XCTAssertNil(A.openHeaderItem(app, header: header, item: item), item)
            A.assertPoints(app, at: header, button: button, what: "\(item) from the group header", test: self)
            app.terminate()
        }
    }
}

/// Reach and measure helpers, shared with the all-UI-states capture scenes.
enum CloseConfirmAnchor {
    enum Position: String, CaseIterable { case top, middle, bottom }

    /// The Mac Studio's rows (mock data): the ones with Close folders.
    static let studioRows: Set<String> = [
        "ws-cmux", "ws-web", "ws-ios", "ws-infra", "ws-ghostty", "ws-design", "ws-blog", "ws-release",
    ]
    static let firstGroup = "alpha"
    static let secondGroup = "beta"

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
            { UIStateCaptureCase.scrollDown(app, times: 2) },
            { UIStateCaptureCase.tap(app.buttons["Close"].firstMatch, "Close folder") },
            { UIStateCaptureCase.tap(app.buttons[kind].firstMatch, kind) },
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

    /// Two groups on the Mac Studio (ws-web in "alpha", ws-ios in "beta"), through
    /// each row's Group > Move Workspace to Group… > Move Workspace to New Group.
    @MainActor
    static func makeTwoGroups(_ app: XCUIApplication) -> String? {
        UIStateCaptureCase.steps([
            { moveToNewGroup(app, rowID: "ws-web", name: firstGroup) },
            { moveToNewGroup(app, rowID: "ws-ios", name: secondGroup) },
        ])
    }

    @MainActor
    static func moveToNewGroup(_ app: XCUIApplication, rowID: String, name: String) -> String? {
        UIStateCaptureCase.steps([
            { UIStateCaptureCase.longPress(app.buttons["workspace.row.\(rowID)"], rowID) },
            { UIStateCaptureCase.scrollDown(app, times: 2) },
            { UIStateCaptureCase.tap(app.buttons["Group"].firstMatch, "Group folder") },
            { UIStateCaptureCase.tap(UIStateCaptureCase.label(app, contains: "Move Workspace to Group"), "Move Workspace to Group…") },
            {
                // With no group yet the new-group item is the folder's only child.
                let item = UIStateCaptureCase.label(app, contains: "Move Workspace to New Group")
                return item.waitForExistence(timeout: 3) && !app.alerts.firstMatch.exists
                    ? UIStateCaptureCase.tap(item, "Move Workspace to New Group") : nil
            },
            {
                let alert = app.alerts["Move Workspace to New Group"]
                guard alert.waitForExistence(timeout: 8) else { return "no new-group alert" }
                let field = alert.textFields.firstMatch
                field.tap()
                field.typeText(name)
                return UIStateCaptureCase.tap(alert.buttons["Create"], "Create")
            },
            { header(app, name, timeout: 15) == nil ? "no \(name) group header" : nil },
        ])
    }

    @MainActor
    static func header(_ app: XCUIApplication, _ name: String, timeout: Double = 5) -> XCUIElement? {
        let header = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'workspace.group.' AND label CONTAINS[c] %@", name)).firstMatch
        return header.waitForExistence(timeout: timeout) ? header : nil
    }

    /// Long press a group header and pick `item` from its menu.
    @MainActor
    static func openHeaderItem(_ app: XCUIApplication, header: XCUIElement, item: String) -> String? {
        UIStateCaptureCase.steps([
            { UIStateCaptureCase.longPress(header, "group header") },
            {
                let button = app.buttons[item].firstMatch
                if !button.waitForExistence(timeout: 3) { _ = UIStateCaptureCase.scrollDown(app, times: 2) }
                return UIStateCaptureCase.tap(button, item)
            },
            { UIStateCaptureCase.wait(dialogTitle(app), "confirmation title", timeout: 8) },
        ])
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

    /// How far the popover sits from its source: 0 when it touches it, else the
    /// gap between them (a popover's padding and arrow make a few dozen points).
    static func gap(_ popover: CGRect, from source: CGRect) -> CGFloat {
        let below = popover.minY - source.maxY
        let above = source.minY - popover.maxY
        return [below, above].filter { $0 >= -2 }.min() ?? .infinity
    }

    /// Popover padding (title inset, arrow) and nothing more.
    static let maxGap: CGFloat = 80

    @MainActor
    static func assertPoints(_ app: XCUIApplication, at source: XCUIElement, button: String, what: String, test: XCTestCase,
                             file: StaticString = #filePath, line: UInt = #line) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = what
        shot.lifetime = .keepAlways
        test.add(shot)
        guard let popover = popover(app, button: button) else {
            XCTFail("\(what): no popover with \(button)\n\(app.debugDescription)", file: file, line: line)
            return
        }
        let gap = gap(popover, from: source.frame)
        print("CLOSE-ANCHOR \(what): source \(source.frame) popover \(popover) gap \(gap)")
        XCTAssertLessThanOrEqual(gap, maxGap, "\(what): the popover \(popover) is \(gap) pt from its source \(source.frame)",
                                 file: file, line: line)
    }
}
