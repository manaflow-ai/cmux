import XCTest

/// Leo, 2026-11-24: "the top bar swiping left and right in ios is really good, but the loading has
/// layout shifts and placeholder states that likely dont need to be so placeholder and better
/// diffed. i think diffing better in ios for ui stuff may help perf and percievef speed/percieved
/// speed to interactivity on ios."
///
/// The top-bar swipe and the app opened again on a chat, the loads `LoadShiftsUITests` (app open,
/// agent and terminal workspace, relaunch) does not swipe through, with its metrics counted per
/// display frame by the app's `LoadFrameProbe` (`CMUX_MOBILE_LOAD_PROBE=1`, `debug.load-probe`):
/// - `placeholder_frames`: frames a loading placeholder was on screen.
/// - `shift_frames`: frames in which a transcript row already drawn moved or resized (> 1 pt)
///   with nobody scrolling.
/// - `ms`: from the swipe's release (or the launch) to the last frame that changed.
/// For each link (`CMUX_MOBILE_MOCK_LINK` wifi, lte, lossy-3: when a chat's history arrives) and
/// load (idle: two mock chats; duress: two chats of 200 replayed turns, every third a pasted raw
/// log), with the row height memory off (`CMUX_MOBILE_ROW_MEMORY=0`, the app as before) and on.
/// The swipes go back and forth between the workspace's two agent tabs (Codex and Claude), so every
/// one lands on a chat page built again from a store that has its turns: a cache exists. Each
/// configuration prints `TOPBARSWIPE {json}` lines with n, median, p90 and max, and attaches them.
final class TopBarSwipeLoadUITests: XCTestCase {
    static let links = ["wifi", "lte", "lossy-3"]
    static let loads = ["idle", "duress"]
    static let swipes = 20
    static let relaunches = 20

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testTopBarSwipesBetweenChats() throws {
        var lines: [String] = []
        for load in Self.loads {
            for link in Self.links {
                for memory in [false, true] {
                    let app = launch(link: link, load: load, memory: memory)
                    guard let address = waitForAddress(app) else {
                        XCTFail("\(load)/\(link): the workspace's address capsule\n\(app.debugDescription)")
                        app.terminate()
                        continue
                    }
                    _ = settle(app, after: Date(), atLeast: 2.0)
                    // The first swipe opens the other chat for the first time (no cache yet): its own
                    // line; every later one lands on a page whose store and rows were seen before.
                    var first: [Sample] = []
                    var left: [Sample] = []
                    var right: [Sample] = []
                    for index in 0 ... Self.swipes * 2 {
                        let toLeft = index % 2 == 0
                        let before = probe(app)
                        swipe(app, address: address, toLeft: toLeft)
                        let released = Date()
                        let after = settle(app, after: released, atLeast: 1.2)
                        let sample = Sample(before: before, after: after, from: released)
                        if index == 0 { first.append(sample) } else if toLeft { left.append(sample) } else { right.append(sample) }
                    }
                    lines.append(Self.line(flow: "swipe-first-visit", load: load, link: link, memory: memory, samples: first, lastMoved: ""))
                    lines.append(Self.line(flow: "swipe", load: load, link: link, memory: memory, samples: left + right,
                                           lastMoved: probe(app).lastMoved))
                    app.terminate()
                }
            }
        }
        report(lines)
    }

    /// The app opened again on the chat it showed (the history comes over the link; the rows kept
    /// from the launch before are the cache), n launches per configuration.
    @MainActor
    func testReopeningOnAChat() throws {
        var lines: [String] = []
        for load in Self.loads {
            for link in Self.links {
                for memory in [false, true] {
                    var samples: [Sample] = []
                    for run in 0 ... Self.relaunches {
                        let start = Date()
                        let app = launch(link: link, load: load, memory: memory)
                        guard waitForAddress(app) != nil else {
                            XCTFail("\(load)/\(link) run \(run): the workspace's address capsule")
                            app.terminate()
                            continue
                        }
                        let after = settle(app, after: start, atLeast: 2.5)
                        // The first launch only fills the memory for the next ones.
                        if run > 0 { samples.append(Sample(before: .zero, after: after, from: start)) }
                        // To the background first, so the app writes what it kept.
                        XCUIDevice.shared.press(.home)
                        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                        app.terminate()
                    }
                    lines.append(Self.line(flow: "reopen", load: load, link: link, memory: memory, samples: samples, lastMoved: ""))
                }
            }
        }
        report(lines)
    }

    // MARK: Driving

    @MainActor
    private func launch(link: String, load: String, memory: Bool) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LOAD_PROBE"] = "1"
        app.launchEnvironment["CMUX_MOBILE_MOCK_LINK"] = link
        app.launchEnvironment["CMUX_MOBILE_ROW_MEMORY"] = memory ? "1" : "0"
        // The list rig opens ws-cmux with a Codex chat first (t-codex-stress), and holds.
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "chat"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0.5"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = load == "duress" ? "200" : "0"
        if load == "duress" { app.launchEnvironment["CMUX_MOBILE_LIST_GIANT"] = "1" }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-tab", "workspaces"]
        app.launch()
        return app
    }

    @MainActor
    private func waitForAddress(_ app: XCUIApplication) -> XCUIElement? {
        let address = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Address, '")).firstMatch
        return address.waitForExistence(timeout: 40) ? address : nil
    }

    /// A quick horizontal drag across the address capsule (TabsKit's toolbar swipe).
    @MainActor
    private func swipe(_ app: XCUIApplication, address: XCUIElement, toLeft: Bool) {
        let from = address.coordinate(withNormalizedOffset: CGVector(dx: toLeft ? 0.85 : 0.15, dy: 0.5))
        let to = address.coordinate(withNormalizedOffset: CGVector(dx: toLeft ? -0.6 : 1.6, dy: 0.5))
        from.press(forDuration: 0.02, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
    }

    struct Probe: Equatable {
        var placeholderFrames = 0
        var shiftFrames = 0
        var lastChangeEpochMs: Double = 0
        var lastMoved = ""
        var memoryUnchanged = 0

        static let zero = Probe()
    }

    @MainActor
    private func probe(_ app: XCUIApplication) -> Probe {
        let label = app.staticTexts["debug.load-probe"].firstMatch
        guard label.exists, let data = label.label.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .zero }
        return Probe(placeholderFrames: json["placeholderFrames"] as? Int ?? 0, shiftFrames: json["shiftFrames"] as? Int ?? 0,
                     lastChangeEpochMs: (json["lastChangeEpochMs"] as? NSNumber)?.doubleValue ?? 0,
                     lastMoved: json["lastMoved"] as? String ?? "", memoryUnchanged: json["memoryUnchanged"] as? Int ?? 0)
    }

    /// Waits at least `atLeast` seconds after `start`, then until no frame changed for 0.6 s
    /// (at most 6 s), and reads the probe.
    @MainActor
    private func settle(_ app: XCUIApplication, after start: Date, atLeast: TimeInterval) -> Probe {
        RunLoop.current.run(until: start.addingTimeInterval(atLeast))
        var last = probe(app)
        while Date().timeIntervalSince(start) < 6 {
            let quiet = Date().timeIntervalSince1970 * 1000 - last.lastChangeEpochMs
            if quiet > 600 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            last = probe(app)
        }
        return last
    }

    struct Sample {
        var placeholderFrames: Int
        var shiftFrames: Int
        var ms: Int

        init(before: Probe, after: Probe, from: Date) {
            placeholderFrames = after.placeholderFrames - before.placeholderFrames
            shiftFrames = after.shiftFrames - before.shiftFrames
            ms = max(0, Int(after.lastChangeEpochMs - from.timeIntervalSince1970 * 1000))
        }
    }

    static func line(flow: String, load: String, link: String, memory: Bool, samples: [Sample], lastMoved: String) -> String {
        func stats(_ values: [Int]) -> [String: Int] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return ["n": 0] }
            return ["n": sorted.count, "sum": sorted.reduce(0, +), "median": sorted[sorted.count / 2],
                    "p90": sorted[min(sorted.count - 1, sorted.count * 9 / 10)], "max": sorted.last ?? 0,
                    "nonzero": sorted.filter { $0 > 0 }.count]
        }
        let json: [String: Any] = [
            "flow": flow, "load": load, "link": link, "memory": memory ? "on" : "off",
            "placeholder_frames": stats(samples.map(\.placeholderFrames)),
            "shift_frames": stats(samples.map(\.shiftFrames)),
            "ms": stats(samples.map(\.ms)),
            "last_moved": lastMoved,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        return "TOPBARSWIPE " + (String(data: data, encoding: .utf8) ?? "{}")
    }

    @MainActor
    private func report(_ lines: [String]) {
        let summary = lines.joined(separator: "\n")
        print(summary)
        let attachment = XCTAttachment(string: summary)
        attachment.name = "TOPBARSWIPE"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
