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
        /// The back control on the page (nil: the system navigation bar's own back button).
        let back: String?
        /// Back from the list to this page (nil: a fresh launch, whose demo pushes it again).
        let reopen: String?
    }

    static let terminal = Page(name: "terminal", demo: "ws-terminal-idle", field: "terminal.composer.field",
                               shown: "workspace.ws-cmux", back: "Back", reopen: "workspace.row.ws-cmux")
    static let workspaceChat = Page(name: "workspace-chat", demo: "ws-chat-idle", field: "chat.composer.card",
                                    shown: "workspace.ws-cmux", back: "Back", reopen: "workspace.row.ws-cmux")
    /// The agent chat pushed from Home (the system bar on both pages).
    static let homeChat = Page(name: "home-chat", demo: "disclosure-chat", field: "chat.composer.card",
                               shown: "chat.composer.card", back: nil, reopen: nil)

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
        run(Self.homeChat)
    }

    /// The same swipes with the whole-page behavior off (`-CmuxMobileSwipeBackLegacy`): the
    /// before of the recording. Setup still asserts; known broken transition behavior is recorded.
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
        let probe = app.staticTexts["debug.whole-page"]
        guard probe.waitForExistence(timeout: 10) else {
            attach(app, "\(label)-missing-probe")
            XCTFail("\(label): the DEBUG transition probe did not start\n\(app.debugDescription)")
            return
        }
        let shown = app.descendants(matching: .any)[page.shown]
        let row = page.reopen.map { app.buttons[$0] }
        /// The probe's readings, one per launch.
        var readings: [String] = []
        func reading() -> String {
            guard probe.waitForExistence(timeout: 5) else { return "samples=0 (no probe)" }
            return probe.value as? String ?? ""
        }

        func openPage(_ step: String, quiet: Bool = false) -> Bool {
            let field = app.descendants(matching: .any)[page.field]
            if !shown.waitForExistence(timeout: 30) || !field.waitForExistence(timeout: 20) {
                if !quiet { XCTFail("\(label) \(step): the page or its composer \(page.field) did not show") }
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

        /// The page again: from its row, else a fresh launch (the probe keeps counting per launch,
        /// so the earlier launch's reading is taken first).
        func reopen(_ step: String) -> Bool {
            if let row, row.waitForExistence(timeout: 5) {
                row.tap()
                if openPage(step, quiet: true) { return true }
            }
            readings.append(reading())
            app.terminate()
            app.launch()
            return openPage(step)
        }

        func back(to step: String) {
            if let row {
                XCTAssertTrue(row.waitForExistence(timeout: 10), "\(label) \(step): back on Workspaces")
            } else {
                XCTAssertTrue(shown.waitForNonExistence(timeout: 10), "\(label) \(step): the page is gone")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            if !legacy {
                let tabs = app.tabBars.firstMatch
                XCTAssertTrue(tabs.waitForExistence(timeout: 5), "\(label) \(step): the root tab bar returns after the pop")
                if row != nil {
                    let newTask = app.buttons["workspaces.newTask"]
                    XCTAssertTrue(newTask.waitForExistence(timeout: 5) && newTask.isHittable,
                                  "\(label) \(step): New Task is usable after the page leaves")
                }
            }
        }

        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        steps: do {
            // 1. A swipe from the edge to mid screen, held, then let go: the pop finishes.
            guard openPage("held") else { break steps }
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
            guard reopen("cancel") else { break steps }
            edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45)),
                       withVelocity: 120, thenHoldForDuration: 0.8)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            XCTAssertTrue(shown.exists && shown.isHittable && !(row?.isHittable ?? false),
                          "\(label): a short swipe let go slowly is cancelled")
            if !legacy {
                // A cancelled swipe keeps the page: root chrome stays out over it.
                XCTAssertFalse(app.tabBars.firstMatch.isHittable, "\(label): the root tab bar shows over a page after a cancelled swipe")
            }
            attach(app, "\(label)-cancel-after")
            if keyboard {
                // The dock as it was before the swipe, the composer usable.
                let usable = app.descendants(matching: .any)[page.field].isHittable
                if legacy {
                    print("CMUX_WHOLE_PAGE \(label): cancelledComposerUsable=\(usable)")
                } else {
                    XCTAssertTrue(usable, "\(label): the composer is usable after a cancelled swipe")
                }
            }

            // 3. The back button.
            let button = page.back.map { app.buttons[$0].firstMatch }
                ?? app.navigationBars.firstMatch.buttons.element(boundBy: 0)
            if button.waitForExistence(timeout: 5), button.isHittable {
                button.tap()
            } else {
                XCTFail("\(label): no back button \(page.back ?? "in the navigation bar")")
                edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.45)),
                           withVelocity: .fast, thenHoldForDuration: 0)
            }
            back(to: "button")
        }
        readings.append(reading())

        let text = readings.joined(separator: "\n")
        let note = XCTAttachment(string: text)
        note.name = "\(label)-probe"
        note.lifetime = .keepAlways
        add(note)
        print("CMUX_WHOLE_PAGE \(label): \(text)")
        guard !legacy else { return }
        for line in readings {
            let values = Dictionary(line.split(separator: " ").compactMap { pair -> (String, String)? in
                let kv = pair.split(separator: "=", maxSplits: 1)
                return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
            }, uniquingKeysWith: { _, last in last })
            guard let samples = Int(values["samples"] ?? ""),
                  let drift = Int(values["drift"] ?? ""),
                  let stray = Int(values["stray"] ?? ""),
                  let bar = Int(values["bar"] ?? "") else {
                XCTFail("\(label): incomplete transition measurement (\(line))")
                continue
            }
            XCTAssertGreaterThan(samples, 3, "\(label): the probe saw no transition frames (\(line))")
            XCTAssertLessThanOrEqual(drift, 2,
                                     "\(label): a piece of the page was left behind as it slid (\(line))")
            XCTAssertLessThanOrEqual(stray, 2,
                                     "\(label): a layer outside the page drew over it as it slid (\(line))")
            XCTAssertLessThanOrEqual(bar, 1,
                                     "\(label): the Workspaces bar drew over the page (doubled bars) (\(line))")
        }
    }

    @MainActor
    func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
