import XCTest

/// Leo, 2026-11-22: "if the phone is simply browsing the opened tabs on the mac, there should be no
/// reason for there to be so many blank favicons and blank previews and blank pages."
/// Done metric: 0 blank cards and 0 blank favicons when the tab grid opens cold, counted over 20 tabs.
///
/// The mock workspace (`CMUX_MOBILE_LIST_SCREEN=tabs`, `LIST_COUNT=20`) has agents at t-g0, 3, ..., 18,
/// terminals at 1, 4, ..., 19 and browsers at 2, 5, ..., 17; t-g0 is the open tab.
/// Launch 1 (`CMUX_MOBILE_LIST_MAC_CARDS=1`) has the mock Mac push its `tabs` records through
/// `MacTabCards` (a favicon and thumbnail per browser, a screen per terminal), kept on disk, and scrolls
/// the grid so the phone draws and keeps its own agent pictures. Launch 2 is cold: no Mac push, no card
/// pictures drawn (`CMUX_MOBILE_LIST_NO_CARD_PICTURES=1`), so a card can only show what the disk holds.
///
/// Counted from `TabCardFaceProbe` (`tabgrid.cardfaces.probe`), over the cards the grid built while
/// scrolled through once (a card the grid never builds counts as blank: `unbuilt`):
/// - blank card: agent `live` (not the open tab) or no face; terminal `placeholder` or `connecting`;
///   browser `placeholder` (the globe).
/// - blank favicon: a browser tab whose favicon slot drew no image. Agent and terminal tabs show their
///   kind's glyph, which is not a blank favicon.
/// Asserted 0: terminal and browser cards, browser favicons (the mock Mac pushed all of them), and every
/// agent card whose picture launch 1 wrote to disk. Reported only: agent cards launch 1 did not write.
final class TabGridColdOpenBlankCountUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private static let tabCount = 20
    private static let activeTab = "t-g0"

    @MainActor
    func testColdOpenedGridHasNoBlankCardsOrFavicons() throws {
        // Launch 1: the mock Mac pushes its records; the phone draws and keeps its agent pictures.
        let first = Self.makeApp(macCards: true)
        first.launch()
        Self.passTeamChooser(first)
        let seeded = Self.wait(first, timeout: 90) { $0.grid && $0.macSeeded >= Self.expectedMacRows }
        print("CMUX_TAB_BLANK launch1 seeded: \(seeded.raw)")
        XCTAssertGreaterThanOrEqual(seeded.macSeeded, Self.expectedMacRows,
                                    "launch 1: the mock Mac's records (\(Self.expectedMacRows)) were not written to disk: \(seeded.raw)")
        Self.scrollThrough(first)
        let written = Self.state(first)
        print("CMUX_TAB_BLANK launch1 end: \(written.raw)")
        first.terminate()

        // Launch 2: cold. Nothing pushed and no picture drawn in this launch.
        let second = Self.makeApp(macCards: false)
        second.launch()
        Self.passTeamChooser(second)
        let shown = Self.wait(second, timeout: 90) { $0.grid }
        XCTAssertTrue(shown.grid, "launch 2: the grid never showed: \(shown.raw)")
        XCTAssertEqual(shown.macSeeded, 0, "launch 2 must not seed: \(shown.raw)")
        Self.scrollThrough(second)
        let cold = Self.state(second)
        print("CMUX_TAB_BLANK launch2 end: \(cold.raw)")

        let tabs = (0 ..< Self.tabCount).map { "t-g\($0)" }
        var blankCards: [String] = []
        var unbuilt: [String] = []
        var blankFavicons: [String] = []
        var unsavedAgents: [String] = []
        for tab in tabs {
            let kind = Self.kind(tab)
            guard let face = cold.faces[tab]?.now else {
                unbuilt.append(tab)
                blankCards.append(tab)
                if kind == "browser" { blankFavicons.append(tab) }
                continue
            }
            let blank: Bool
            switch kind {
            case "agent": blank = tab == Self.activeTab ? false : !(face == "lastKnown" || face == "picture")
            case "terminal": blank = face == "placeholder" || face == "connecting"
            default: blank = face == "placeholder"
            }
            if blank {
                blankCards.append(tab)
                if kind == "agent", !written.saved.contains(tab) { unsavedAgents.append(tab) }
            }
            if kind == "browser", cold.favicons[tab]?.now != true { blankFavicons.append(tab) }
        }

        var report = [
            "blank cards = \(blankCards.count) of \(Self.tabCount)",
            "blank favicons = \(blankFavicons.count) of \(Self.tabCount)",
            "blank cards by tab: \(blankCards.joined(separator: ","))",
            "blank favicons by tab (browser tabs only): \(blankFavicons.joined(separator: ","))",
            "cards never built while scrolling: \(unbuilt.joined(separator: ","))",
            "blank agent cards launch 1 did not write: \(unsavedAgents.joined(separator: ","))",
            "probe: \(cold.raw)",
        ]
        report.insert("blank by kind: " + ["agent", "terminal", "browser"].map { kind in
            "\(kind)=\(blankCards.filter { Self.kind($0) == kind }.count)"
        }.joined(separator: " "), at: 2)
        for line in report { print("CMUX_TAB_BLANK \(line)") }
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "blank-count"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Asserted: what the disk can fill.
        let mustFill = blankCards.filter { Self.kind($0) != "agent" || written.saved.contains($0) }
        XCTAssertEqual(mustFill, [], "launch 2: cards blank though the Mac's records or launch 1's pictures were on disk: \(report.joined(separator: " | "))")
        XCTAssertEqual(blankFavicons, [], "launch 2: browser favicons blank though the mock Mac pushed them: \(report.joined(separator: " | "))")
    }

    /// 6 browsers and 7 terminals of the 20 tabs.
    private static var expectedMacRows: Int {
        (0 ..< tabCount).filter { kind("t-g\($0)") != "agent" }.count
    }

    // MARK: Scrolling

    /// Scrolls the grid to its end and back, letting each stop settle, so the grid builds every card.
    @MainActor
    private static func scrollThrough(_ app: XCUIApplication) {
        pause(3)
        for _ in 0 ..< 6 {
            app.swipeUp(velocity: .slow)
            pause(1.5)
        }
        for _ in 0 ..< 6 {
            app.swipeDown(velocity: .slow)
            pause(1.5)
        }
        pause(2)
    }

    @MainActor
    private static func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Launch setup

    @MainActor
    private static func makeApp(macCards: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "tabs"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = String(tabCount)
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        if macCards {
            app.launchEnvironment["CMUX_MOBILE_LIST_MAC_CARDS"] = "1"
        } else {
            app.launchEnvironment["CMUX_MOBILE_LIST_NO_CARD_PICTURES"] = "1"
        }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                "-cmux-mobile-card-face-probe"]
        return app
    }

    /// First run of mock data: pick the team whose Mac holds the workspace.
    @MainActor
    private static func passTeamChooser(_ app: XCUIApplication) {
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5), app.buttons["Manaflow"].exists { app.buttons["Manaflow"].tap() }
    }

    /// The rig's tab kinds (`ListStressRig.tabs`): agent, terminal, browser in turn.
    private static func kind(_ tab: String) -> String {
        guard let index = Int(tab.dropFirst("t-g".count)) else { return "?" }
        return ["agent", "terminal", "browser"][index % 3]
    }

    // MARK: The probe

    /// `TabCardFaceProbe`'s value: `grid=1 macseeded=13 saves=N saved=t-g3 t-g3=live>lastKnown icon:t-g2=0>1 ...`.
    private struct Faces {
        var raw: String
        var grid = false
        var macSeeded = 0
        var saved: Set<String> = []
        /// Per tab: the face its card drew first in the launch, and the face it draws now.
        var faces: [String: (first: String, now: String)] = [:]
        /// Per browser tab: whether its favicon slot drew an image, first and now.
        var favicons: [String: (first: Bool, now: Bool)] = [:]

        init(_ raw: String) {
            self.raw = raw
            for token in raw.split(separator: " ") {
                let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let pair = parts[1].split(separator: ">").map(String.init)
                switch parts[0] {
                case "grid": grid = parts[1] == "1"
                case "macseeded": macSeeded = Int(parts[1]) ?? 0
                case "saves": break
                case "saved": saved = parts[1] == "-" ? [] : Set(parts[1].split(separator: ",").map(String.init))
                case let key where key.hasPrefix("icon:"):
                    if pair.count == 2 { favicons[String(key.dropFirst(5))] = (first: pair[0] == "1", now: pair[1] == "1") }
                default:
                    if pair.count == 2 { faces[parts[0]] = (first: pair[0], now: pair[1]) }
                }
            }
        }
    }

    @MainActor
    private static func state(_ app: XCUIApplication) -> Faces {
        let probe = app.staticTexts["tabgrid.cardfaces.probe"].firstMatch
        guard probe.exists else { return Faces("") }
        return Faces((probe.value as? String) ?? "")
    }

    /// Reads the probe until `done` holds or `timeout` passes; returns the last read.
    @MainActor
    private static func wait(_ app: XCUIApplication, timeout: TimeInterval, until done: (Faces) -> Bool) -> Faces {
        let deadline = Date().addingTimeInterval(timeout)
        var last = state(app)
        while !done(last), Date() < deadline {
            pause(0.25)
            last = state(app)
        }
        return last
    }
}
