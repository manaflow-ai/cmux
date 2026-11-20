import XCTest

/// Leo, 2026-11-17 (softened): "Surely we can just calculate a terminal size
/// and resize whatever needs exceptions, falling back if need be. Plus the
/// loading of everything needs to be FASTER."
///
/// The terminal demo's attach (`-CmuxMobileTerminalDemoAttach`): the phone
/// opens a terminal page onto htop already running on a Mac pane of 120x40,
/// the Mac answering the attach two round trips later (identify, then
/// attach-surface, as the app makes them) and each resize one, of 60 ms (LTE). The page
/// traces each step of the attach (``TerminalAttachTrace``) up to the first
/// frame that shows htop at its final grid with nothing held, replayed,
/// queued, settling or unanswered. The app is launched `runs` times; each
/// run's trace and the median go in the `attach-first-frame` attachment (the
/// PR's phase table reads it).
final class TerminalAttachFirstFrameUITests: XCTestCase {
    private let runs = 8

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testAttachIntoHtopFirstRightFrame() throws {
        XCUIDevice.shared.orientation = .portrait
        var lines: [String] = []
        var first: [Int] = []
        var fromStart: [Int] = []
        for run in 1...runs {
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                    "-CmuxMobileTerminalDemoAttach"]
            app.launch()
            let probe = app.staticTexts["debug.terminal-demo"]
            XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")
            let deadline = Date().addingTimeInterval(20)
            var label = probe.label
            while Date() < deadline, !label.hasPrefix("attach.done") {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                label = probe.label
            }
            if run == 1 {
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "attach-htop"
                shot.lifetime = .keepAlways
                add(shot)
            }
            lines.append("attach first frame: run \(run): \(label)")
            func value(_ key: String) -> Int? {
                label.split(separator: " ").first { $0.hasPrefix(key + "=") }.flatMap { Int($0.dropFirst(key.count + 1)) }
            }
            if let ms = value("first"), ms >= 0 { first.append(ms) }
            if let ms = value("fromstart"), ms >= 0 { fromStart.append(ms) }
            app.terminate()
        }
        func median(_ values: [Int]) -> Int {
            let sorted = values.sorted()
            return sorted.isEmpty ? -1 : sorted[sorted.count / 2]
        }
        lines.append("attach first frame: median from view load \(median(first)) ms \(first), from session start \(median(fromStart)) ms \(fromStart)")
        for line in lines { print(line) }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "attach-first-frame"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTContext.runActivity(named: lines.last ?? "") { _ in }
        XCTAssertEqual(first.count, runs, "every run reached a right frame:\n\(lines.joined(separator: "\n"))")
    }
}
