import XCTest

/// Leo, 2026-11-25: "The swiping back animation has tons of bullshit overlap and weird looking
/// zones esp near composer bar when there's a background it all doesn't move properly".
///
/// A swipe back from a pushed page moves the whole page as one: its content, its ground (the
/// Mac's picture), its composer and the glass around it, and its own header. The Workspaces bar
/// never draws over a page that hides it. The `debug.whole-page` probe (`-CmuxMobileWholePageProbe`,
/// WholePageProbe.swift) reads every frame of each transition, as drawn:
/// - `drift`: the most a piece of the top page moved against the page's edge (a piece left behind);
/// - `stray`: the most a layer in neither page drew over the top page;
/// - `bar`: the most the navigation bar drew over a page that hides it.
///
/// Each case runs a held half swipe that is let go (it finishes), a short swipe that is
/// cancelled, and the page's back button, with the keyboard down and up, with and without the
/// Mac's picture, in dark and light.
final class SwipeBackWholePageUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.appearance = .dark }
    }

    struct Page {
        let name: String
        let demo: String
        let field: String
        /// The page's identifier once it is on screen.
        let shown: String
        /// The back control on the page (nil: the bar's own back button).
        let back: String?
        /// Back from the list to this page (nil: only the held swipe runs).
        let reopen: String?
    }

    static let terminal = Page(name: "terminal", demo: "ws-terminal-idle", field: "terminal.composer.field",
                               shown: "workspace.ws-cmux", back: "Back", reopen: "workspace.row.ws-cmux")
    static let workspaceChat = Page(name: "workspace-chat", demo: "ws-chat-idle", field: "chat.composer.field",
                                    shown: "workspace.ws-cmux", back: "Back", reopen: "workspace.row.ws-cmux")
    /// The agent chat pushed from Home (the system bar on both pages).
    static let homeChat = Page(name: "home-chat", demo: "disclosure-chat", field: "chat.composer.field",
                               shown: "chat.composer.field", back: nil, reopen: nil)

    @MainActor
    func testTerminalPageMovesAsOne() {
        run(Self.terminal)
    }

    @MainActor
    func testWorkspaceAgentChatMovesAsOne() {
        run(Self.workspaceChat)
    }

    @MainActor
    func testHomeAgentChatMovesAsOne() {
        run(Self.homeChat, appearances: [.dark])
    }

    /// The same swipes with the whole-page behavior off (`-CmuxMobileSwipeBackLegacy`): the
    /// before of the recording, and proof the probe sees what Leo saw. Records, asserts nothing.
    @MainActor
    func testBeforeLegacy() {
        run(Self.terminal, appearances: [.dark], legacy: true)
        run(Self.workspaceChat, appearances: [.dark], legacy: true)
    }

    @MainActor
    func run(_ page: Page, appearances: [XCUIDevice.Appearance] = [.dark, .light], legacy: Bool = false) {
        for appearance in appearances {
            for picture in [true, false] {
                for keyboard in [false, true] {
                    let label = "\(legacy ? "before-" : "")\(page.name)-\(appearance == .dark ? "dark" : "light")-\(picture ? "picture" : "plain")-kb\(keyboard ? "up" : "down")"
                    XCTContext.runActivity(named: label) { _ in
                        XCUIDevice.shared.appearance = appearance
                        check(page, label: label, picture: picture, keyboard: keyboard, legacy: legacy)
                    }
                }
            }
        }
    }

    @MainActor
    func check(_ page: Page, label: String, picture: Bool, keyboard: Bool, legacy: Bool) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-demo", page.demo,
                                "-cmux-mobile-mac-appearance", picture ? "mocha-wallpaper" : "default",
                                "-CmuxMobileWholePageProbe"] + (legacy ? ["-CmuxMobileSwipeBackLegacy"] : [])
        app.launch()
        defer { app.terminate() }
        let shown = app.descendants(matching: .any)[page.shown]
        let row = page.reopen.map { app.buttons[$0] }

        func openPage(_ step: String) -> Bool {
            if !shown.waitForExistence(timeout: 30) {
                XCTFail("\(label) \(step): the page did not open\n\(app.debugDescription)")
                return false
            }
            let field = app.textViews[page.field]
            if !field.waitForExistence(timeout: 20) {
                XCTFail("\(label) \(step): no composer \(page.field)")
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            if keyboard {
                field.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), "\(label) \(step): keyboard did not show")
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            }
            attach(app, "\(label)-\(step)-open")
            return true
        }

        func back(to step: String) {
            if let row {
                XCTAssertTrue(row.waitForExistence(timeout: 10), "\(label) \(step): back on Workspaces")
            } else {
                XCTAssertTrue(shown.waitForNonExistence(timeout: 10), "\(label) \(step): the page is gone")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }

        // 1. A swipe from the edge to mid screen, held, then let go: the pop finishes.
        guard openPage("held") else { return }
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45)),
                   withVelocity: 250, thenHoldForDuration: 1.2)
        if shown.exists, shown.isHittable {
            // Let go short of the middle: finish it with a full swipe.
            edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.45)),
                       withVelocity: .fast, thenHoldForDuration: 0)
        }
        back(to: "held")
        attach(app, "\(label)-held-after")

        // 2. A short swipe let go slowly: cancelled, the page stays.
        if let row {
            row.tap()
            guard openPage("cancel") else { return }
            edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45)),
                       withVelocity: 120, thenHoldForDuration: 0.8)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            XCTAssertTrue(shown.exists && !row.isHittable, "\(label): a short swipe let go slowly is cancelled")
            attach(app, "\(label)-cancel-after")
            if keyboard {
                // The keyboard and the dock as they were before the swipe.
                XCTAssertTrue(app.textViews[page.field].isHittable, "\(label): the composer is usable after a cancelled swipe")
            }
        }

        // 3. The back button.
        if row != nil, let backLabel = page.back {
            let button = app.buttons.matching(identifier: backLabel).firstMatch
            let found = button.waitForExistence(timeout: 5) ? button : app.buttons[backLabel]
            if found.exists, found.isHittable {
                found.tap()
            } else {
                XCTFail("\(label): no back button \(backLabel)")
                edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.45)),
                           withVelocity: .fast, thenHoldForDuration: 0)
            }
            back(to: "button")
        }

        let probe = app.staticTexts["debug.whole-page"]
        guard probe.waitForExistence(timeout: 5) else {
            XCTFail("\(label): no whole-page probe")
            return
        }
        let line = probe.value as? String ?? ""
        print("CMUX_WHOLE_PAGE \(label): \(line)")
        XCTContext.runActivity(named: "\(label): \(line)") { _ in }
        let values = Dictionary(line.split(separator: " ").compactMap { pair -> (String, String)? in
            let kv = pair.split(separator: "=", maxSplits: 1)
            return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
        }, uniquingKeysWith: { _, last in last })
        guard !legacy else { return }
        let samples = Int(values["samples"] ?? "") ?? 0
        XCTAssertGreaterThan(samples, 3, "\(label): the probe saw no transition frames (\(line))")
        XCTAssertLessThanOrEqual(Int(values["drift"] ?? "") ?? .max, 2,
                                 "\(label): a piece of the page was left behind as it slid (\(line))")
        XCTAssertLessThanOrEqual(Int(values["stray"] ?? "") ?? .max, 2,
                                 "\(label): a layer outside the page drew over it as it slid (\(line))")
        XCTAssertLessThanOrEqual(Int(values["bar"] ?? "") ?? .max, 1,
                                 "\(label): the Workspaces bar drew over the page (doubled bars) (\(line))")
    }

    @MainActor
    func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
