import XCTest

/// A tab grid opened after a cold launch shows each tab's last-known picture
/// (`TabCardSnapshots`, `Caches/cmux-mobile-tab-snapshots`), not a blank card.
/// Leo, 2026-11-22: "and why do we not have cached previews of the other tabs." and
/// "there should be no reason for there to be so many blank favicons and blank previews and blank pages."
///
/// Launch 1 opens the grid of the mock workspace (the list rig, `CMUX_MOBILE_LIST_SCREEN=tabs`:
/// agents at t-g0, t-g3, t-g6, terminals at 1, 4, 7, browsers at 2, 5, 8; t-g0 active) and
/// waits until every other agent card's picture is written to disk. It then opens browser
/// t-g2 and goes back to the grid, which keeps that page's snapshot (only when the page could
/// be shown: it is the one browser card this can cover, and it needs the simulator's network).
/// Launch 2 is cold, with agent cards never drawn into pictures in this launch
/// (`CMUX_MOBILE_LIST_NO_CARD_PICTURES=1`), so a card can show a picture only from the disk:
/// as the grid shows, every other agent card draws its last-known picture, not its live
/// page of transcript, and this launch wrote none of them.
///
/// What each card draws is read from `TabCardFaceProbe` (`-cmux-mobile-card-face-probe`):
/// a grid card is one accessibility element, so its content carries no identifier.
/// Not covered: terminal cards (they keep their own saved screen, not `TabCardSnapshots`),
/// browser cards whose page this phone never showed (no Mac in mock data sends one: they
/// stay the globe placeholder), and the Mac's streamed pages (`StreamedBrowserCard`).
final class TabCardColdLaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private static let tabCount = 9
    private static let activeTab = "t-g0"
    /// The agent cards other than the active tab's (the active card is the live page).
    private static let otherAgents = ["t-g3", "t-g6"]
    private static let openedBrowser = "t-g2"

    @MainActor
    func testGridCardsShowLastKnownPicturesAfterColdLaunch() throws {
        // Launch 1: the grid draws its agent cards and keeps their pictures.
        let first = Self.makeApp(cardPictures: true)
        first.launch()
        Self.passTeamChooser(first)
        let drawn = Self.wait(first, timeout: 90) { state in
            state.grid && Self.otherAgents.allSatisfy { state.saved.contains($0) }
        }
        print("CMUX_TAB_SNAPSHOT launch1 drawn: \(drawn.raw)")
        XCTAssertTrue(drawn.grid && Self.otherAgents.allSatisfy { drawn.saved.contains($0) },
                      "launch 1: the grid's agent cards \(Self.otherAgents) were not all written to disk: \(drawn.raw)")

        // The one browser page this phone shows: its snapshot is kept as the grid opens over it.
        let browserKept = Self.keepBrowserPicture(first)
        print("CMUX_TAB_SNAPSHOT launch1 browser \(Self.openedBrowser) kept=\(browserKept): \(Self.state(first).raw)")
        // The pictures are written off the main thread: all of them are on disk before the kill.
        let written = Self.state(first)
        first.terminate()

        // Launch 2, cold: nothing drawn this launch, so a card's picture comes from the disk.
        let second = Self.makeApp(cardPictures: false)
        second.launch()
        Self.passTeamChooser(second)
        let shown = Self.wait(second, timeout: 90) { $0.grid }
        XCTAssertTrue(shown.grid, "launch 2: the grid never showed: \(shown.raw)")
        print("CMUX_TAB_SNAPSHOT launch2 grid shown: \(shown.raw)")
        // A card built while the grid was hidden updates as it shows; no picture can be drawn
        // in this launch, so the only change a card can make is to a picture read from disk.
        let settled = Self.wait(second, timeout: 2) { state in
            Self.otherAgents.allSatisfy { state.faces[$0] == nil || state.faces[$0]?.now == "lastKnown" }
        }
        print("CMUX_TAB_SNAPSHOT launch2 cards: \(settled.raw)")

        let agentCards = settled.faces.keys.filter { Self.otherAgents.contains($0) }.sorted()
        XCTAssertFalse(agentCards.isEmpty, "launch 2: no agent card other than \(Self.activeTab) was built: \(settled.raw)")
        for tab in agentCards {
            XCTAssertEqual(settled.faces[tab]?.now, "lastKnown",
                           "launch 2: agent card \(tab) does not show its last-known picture (live: a page of transcript, " +
                           "the blank-then-shifting card): \(settled.raw)")
            XCTAssertFalse(settled.saved.contains(tab), "launch 2: \(tab)'s picture was drawn in this launch, not read from disk: \(settled.raw)")
        }
        // Every agent card the grid built shows a picture: none is live or blank.
        for (tab, face) in settled.faces where Self.kind(tab) == "agent" && tab != Self.activeTab {
            XCTAssertEqual(face.now, "lastKnown", "launch 2: agent card \(tab) draws \(face.now): \(settled.raw)")
        }

        if browserKept {
            XCTAssertEqual(settled.faces[Self.openedBrowser]?.now, "lastKnown",
                           "launch 2: browser card \(Self.openedBrowser), shown on this phone in launch 1, is not its last-known picture: \(settled.raw)")
        } else {
            print("CMUX_TAB_SNAPSHOT browser not covered: launch 1 kept no picture of \(Self.openedBrowser) (page not shown or no network): \(written.raw)")
        }
        // Reported, not asserted: browser cards this phone never showed have nothing to show.
        for (tab, face) in settled.faces.sorted(by: { $0.key < $1.key }) where Self.kind(tab) == "browser" && tab != Self.openedBrowser {
            print("CMUX_TAB_SNAPSHOT browser \(tab) never shown on this phone: \(face.now)")
        }
    }

    // MARK: Launch 1's browser page

    /// Opens browser t-g2 from the grid, lets its page load, and opens the grid over it
    /// (`overviewWillAppear` keeps the active page's snapshot). True once its picture is on disk.
    /// Never fails the test: a page that cannot load leaves the browser leg uncovered.
    @MainActor
    private static func keepBrowserPicture(_ app: XCUIApplication) -> Bool {
        let card = app.buttons["Docs 2, tab"].firstMatch
        guard card.waitForExistence(timeout: 10), card.isHittable else {
            print("CMUX_TAB_SNAPSHOT no hittable card for \(openedBrowser)")
            return false
        }
        card.tap()
        // The page's load: no signal the test can read, so a fixed wait.
        Thread.sleep(forTimeInterval: 8)
        let tabsButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs' OR label BEGINSWITH[c] 'Show All Tabs' OR label BEGINSWITH[c] 'Tab overview'")).firstMatch
        guard tabsButton.waitForExistence(timeout: 15) else {
            print("CMUX_TAB_SNAPSHOT no Tabs button on \(openedBrowser)'s page")
            return false
        }
        tabsButton.tap()
        let kept = wait(app, timeout: 20) { $0.grid && $0.saved.contains(openedBrowser) }
        return kept.saved.contains(openedBrowser)
    }

    // MARK: Launch setup

    @MainActor
    private static func makeApp(cardPictures: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "tabs"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = String(tabCount)
        // Hold the grid still: no scroll passes.
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        if !cardPictures { app.launchEnvironment["CMUX_MOBILE_LIST_NO_CARD_PICTURES"] = "1" }
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

    /// `TabCardFaceProbe`'s value: `grid=1 saves=N saved=t-g3,t-g6 t-g3=live>lastKnown ...`.
    private struct Faces {
        var raw: String
        var grid = false
        var saved: Set<String> = []
        /// Per tab: the face its card drew first in the launch, and the face it draws now.
        var faces: [String: (first: String, now: String)] = [:]

        init(_ raw: String) {
            self.raw = raw
            for token in raw.split(separator: " ") {
                let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "grid":
                    grid = parts[1] == "1"
                case "saves":
                    break
                case "saved":
                    saved = parts[1] == "-" ? [] : Set(parts[1].split(separator: ",").map(String.init))
                default:
                    let face = parts[1].split(separator: ">").map(String.init)
                    if face.count == 2 { faces[parts[0]] = (first: face[0], now: face[1]) }
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            last = state(app)
        }
        return last
    }
}
