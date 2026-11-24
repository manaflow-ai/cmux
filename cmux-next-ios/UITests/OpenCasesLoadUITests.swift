import XCTest

/// Leo, 2026-11-24: "the top bar swiping left and right in ios is really good, but the loading has
/// layout shifts and placeholder states that likely dont need to be so placeholder and better
/// diffed. i think diffing better in ios for ui stuff may help perf and percievef speed/percieved
/// speed to interactivity on ios."
///
/// Three opens, each counted per display frame by the app's `LoadFrameProbe` (as in
/// `TopBarSwipeLoadUITests`: `placeholder_frames` counts frames with "Loading chat…", a list
/// skeleton, or a shown Connecting/Reconnecting/Updating chip on screen; `shift_frames` counts
/// frames in which a drawn row moved or resized with nobody scrolling; `ms` runs from the launch
/// to the last frame that changed):
/// - `kept-chat-link-down`: the app relaunched onto the chat it showed, the Mac's link down (the
///   history never comes, `CMUX_MOBILE_MOCK_LINK=1800000,0,0`). For #53904.
/// - `cache-updating`: the app relaunched onto that chat over a slow link (the history 12 s late),
///   past the 10 s bound a quiet "Updating" waits. For #53810.
/// - `restore-last-place`: the app relaunched where it was, the chat scrolled up first. For #53910.
/// Each idle (two mock chats) and under duress (two chats of 200 turns, every third a pasted raw
/// log), n relaunches, the first launch only opening the chat. A tree without the PR is its
/// before, the same suite on the PR's tree its after. Prints `OPENCASE {json}` lines.
final class OpenCasesLoadUITests: XCTestCase {
    static let loads = ["idle", "duress"]
    static let relaunches = 20

    struct Case {
        var name: String
        var link: String
        var window: TimeInterval
        var scrollsUp: Bool
    }

    static let cases = [
        Case(name: "kept-chat-link-down", link: "1800000,0,0", window: 5, scrollsUp: false),
        Case(name: "cache-updating", link: "6000,0,0", window: 13, scrollsUp: false),
        Case(name: "restore-last-place", link: "wifi", window: 4, scrollsUp: true),
    ]

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testOpenCases() throws {
        var lines: [String] = []
        for load in Self.loads {
            for open in Self.cases {
                // The first launch opens the chat through the list rig, which the app remembers.
                let first = launch(load: load, link: "wifi", rig: true)
                guard first.buttons.matching(Self.address).firstMatch.waitForExistence(timeout: 40) else {
                    XCTFail("\(load)/\(open.name): the chat did not open\n\(first.debugDescription)")
                    first.terminate()
                    continue
                }
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                if open.scrollsUp { scrollUp(first) }
                leave(first)
                var samples: [TopBarSwipeLoadUITests.Sample] = []
                var onChat = 0
                for _ in 1 ... Self.relaunches {
                    let start = Date()
                    let app = launch(load: load, link: open.link, rig: false)
                    if app.buttons.matching(Self.address).firstMatch.waitForExistence(timeout: 30) { onChat += 1 }
                    RunLoop.current.run(until: start.addingTimeInterval(open.window))
                    samples.append(.init(before: .init(), after: probe(app), from: start))
                    leave(app)
                }
                var line = TopBarSwipeLoadUITests.line(flow: open.name, load: load, link: open.link, memory: true,
                                                      samples: samples, lastMoved: "")
                line = line.replacingOccurrences(of: "TOPBARSWIPE {", with: "OPENCASE {\"on_chat\":\(onChat),")
                lines.append(line)
            }
        }
        let summary = lines.joined(separator: "\n")
        print(summary)
        let attachment = XCTAttachment(string: summary)
        attachment.name = "OPENCASE"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    static let address = NSPredicate(format: "label BEGINSWITH 'Address, '")

    /// No `-cmux-mobile-tab` and no `-cmux-mobile-no-restore`: the launch goes back where the
    /// app was. The first one opens the stress chat through the rig.
    @MainActor
    private func launch(load: String, link: String, rig: Bool) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LOAD_PROBE"] = "1"
        app.launchEnvironment["CMUX_MOBILE_MOCK_LINK"] = link
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = load == "duress" ? "200" : "0"
        if load == "duress" { app.launchEnvironment["CMUX_MOBILE_LIST_GIANT"] = "1" }
        if rig {
            app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "chat"
            app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
            app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0.5"
        }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES"]
        app.launch()
        return app
    }

    @MainActor
    private func scrollUp(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        for _ in 0 ..< 3 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.02, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    /// To the background first, so the app writes where it was and what it kept.
    @MainActor
    private func leave(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        app.terminate()
    }

    @MainActor
    private func probe(_ app: XCUIApplication) -> TopBarSwipeLoadUITests.Probe {
        let label = app.staticTexts["debug.load-probe"].firstMatch
        guard label.exists, let data = label.label.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .init() }
        return .init(placeholderFrames: json["placeholderFrames"] as? Int ?? 0, shiftFrames: json["shiftFrames"] as? Int ?? 0,
                     lastChangeEpochMs: (json["lastChangeEpochMs"] as? NSNumber)?.doubleValue ?? 0,
                     lastMoved: json["lastMoved"] as? String ?? "", memoryUnchanged: json["memoryUnchanged"] as? Int ?? 0)
    }
}
