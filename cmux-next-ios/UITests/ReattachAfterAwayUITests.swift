import XCTest

/// The return after minutes in another app (Leo, 2026-11-24: "I'm there for like multiple minutes at
/// a time. And then I go back to the Cmux internal app and then there's some bullshit about like, you
/// know, the reattaching dot, dot, dot type thing. ... The like multi-second long reattach where like
/// the entire thing is somehow grayed out and I can't interact with anything at all.").
///
/// A before-table probe, read-only on the app: the app is open on a terminal (or an agent chat) in mock
/// mode; per away time (5 s, 1, 5 and 10 min) it goes Home, waits that long (iOS suspends it), then
/// `activate()` and at once taps the composer and types one key. Recorded per return:
///
/// - `first_tap_wall_ms`: wall ms from `activate()` returning to the runner's tap returning (XCUITest
///   waits for the app to be idle first, so a busy main thread shows here);
/// - `first_key_accepted_ms`: terminal, the app's `terminal_key_sent` mark (ms after
///   `willEnterForeground`; the session took the key while attached); chat, wall ms until the typed
///   text is in the field;
/// - `link_back_ms`: terminal, the app's `terminal_frame` mark (first frame drawn attached);
/// - `dim_ms`: how long a screenshot read darker than the one taken just before Home (mean luma
///   below 0.85 of it), sampled for 12 s after the return; `status_ms`: how long a connection status
///   ("Reattaching", "Reconnecting", "Connecting", "offline", "Can't connect") was on screen; `lock_ms`:
///   the AppLock cover (`cmuxMobile.appLock`).
///
/// Each return prints `REATTACH {json}`; screenshots at the return, +0.5 s, +1.5 s, +4 s and +11 s
/// are kept as attachments. Mock mode has no link: link-dependent states need a live daemon.
///
///     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///       --arg test --arg ui=ReattachAfterAwayUITests --arg duress=off --arg duress=heavy \
///       --artifact artifacts/ios-sim/evidence.zip
final class ReattachAfterAwayUITests: XCTestCase {
    static let aways: [TimeInterval] = [5, 60, 300, 600]
    static let sampleSeconds: TimeInterval = 12
    static let shotsAt: [TimeInterval] = [0.5, 1.5, 4, 11]

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func testTerminalReturnAfterMinutes() throws { try run(flow: "terminal") }
    @MainActor func testChatReturnAfterMinutes() throws { try run(flow: "chat") }

    /// The process is killed while in the background (as iOS does under memory pressure), then the
    /// person opens cmux again: a cold launch that restores the last workspace and tab (no
    /// `-cmux-mobile-tab`, no `-cmux-mobile-no-restore`). Mock mode has no link, so the time away
    /// does not change a cold launch here; three runs of 20 s for a spread.
    @MainActor func testKilledInBackgroundRelaunch() throws {
        try run(flow: "terminal", aways: [20, 20, 20], killed: true)
    }

    /// Settings > Require Face ID on (`cmuxMobile.settings.requireFaceID`): the lock window covers the
    /// app on return. The simulator has no passcode, so `canEvaluatePolicy` fails and the lock lifts
    /// with no Face ID sheet: `lock_ms` is the cover's own time, a lower bound of a phone's.
    @MainActor func testRequireFaceIDReturn() throws {
        try run(flow: "terminal", aways: [5, 60], faceID: true)
    }

    @MainActor
    private func run(flow: String, aways: [TimeInterval] = ReattachAfterAwayUITests.aways, killed: Bool = false,
                     faceID: Bool = false) throws {
        let app = ResumeFromSwitchUITests.makeApp()
        if faceID { app.launchArguments += ["-cmuxMobile.settings.requireFaceID", "YES"] }
        app.launch()
        let workspace = flow == "terminal" ? ResumeFromSwitchUITests.terminalWorkspace : ResumeFromSwitchUITests.chatWorkspace
        open(workspace, in: app)
        if flow == "terminal" {
            let field = app.textViews["terminal.composer.field"]
            XCTAssertTrue(field.waitForExistence(timeout: 30), "the terminal composer\n\(app.debugDescription)")
            field.tap()
            field.typeText("~")
            app.buttons["terminal.composer.send"].tap()
        } else {
            XCTAssertTrue(openChatField(app, timeout: 30), "the chat composer\n\(app.debugDescription)")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let variant = killed ? "killed" : faceID ? "faceid" : flow
        for (index, away) in aways.enumerated() {
            returnOnce(app, flow: flow, variant: variant, away: away, index: index, killed: killed)
        }
    }

    @MainActor
    private func returnOnce(_ app: XCUIApplication, flow: String, variant: String, away: TimeInterval, index: Int, killed: Bool) {
        let tag = "\(variant)-\(Int(away))s-\(index)"
        let beforeShot = XCUIScreen.main.screenshot()
        keep(beforeShot, "\(tag)-0-before-home")
        let beforeLuma = Self.meanLuma(beforeShot.image)
        let cycle = (ResumeFromSwitchUITests.marks(app)["cycle"] ?? 0) + 1
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(away))
        if killed {
            // Killed while in the background; the next open is a cold launch that restores the last place.
            app.terminate()
            app.launchArguments = app.launchArguments.filter { $0 != "-cmux-mobile-no-restore" }
            if let tab = app.launchArguments.firstIndex(of: "-cmux-mobile-tab") {
                app.launchArguments.removeSubrange(tab ... min(tab + 1, app.launchArguments.count - 1))
            }
        }
        let start = Date()
        if killed { app.launch() } else { app.activate() }
        func since() -> Double { Date().timeIntervalSince(start) * 1000 }
        var row: [String: Double] = ["activate_wall_ms": since(), "away_s": away, "luma_before": beforeLuma, "killed": killed ? 1 : 0]
        // The screen as it comes back, before any input.
        let first = XCUIScreen.main.screenshot()
        row["first_shot_wall_ms"] = since()
        keep(first, "\(tag)-1-return")
        var samples: [(ms: Double, luma: Double, status: String?, lock: Bool)] = []
        samples.append((row["first_shot_wall_ms"]!, Self.meanLuma(first.image), statusText(app), lockShown(app)))

        // The first tap and key, at once.
        let key = ["q", "z", "#", "%", "~"][index % 5]
        let field = app.textViews[flow == "terminal" ? "terminal.composer.field" : "chat.composer.field"]
        if flow == "chat", !field.exists { _ = openChatField(app, timeout: 10) }
        if killed {
            // Restored into the terminal, or back on the list (then open it again, timed in the tap).
            let restored = field.waitForExistence(timeout: 5)
            row["restored_terminal"] = restored ? 1 : 0
            row["restore_wait_wall_ms"] = since()
            if !restored {
                open(ResumeFromSwitchUITests.terminalWorkspace, in: app)
                _ = field.waitForExistence(timeout: 30)
            }
        }
        field.tap()
        row["first_tap_wall_ms"] = since()
        field.typeText(key)
        row["first_key_typed_wall_ms"] = since()
        if flow == "terminal" {
            app.buttons["terminal.composer.send"].tap()
        } else {
            let deadline = Date().addingTimeInterval(10)
            while !((field.value as? String) ?? "").contains(key), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            row["first_key_accepted_ms"] = since()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }

        // Sample the screen for the rest of the window: luma, status text, the lock cover.
        var shots = Self.shotsAt
        while since() < Self.sampleSeconds * 1000 {
            let shot = XCUIScreen.main.screenshot()
            let ms = since()
            if let next = shots.first, ms >= next * 1000 {
                shots.removeFirst()
                keep(shot, "\(tag)-2-at-\(Int(next * 1000))ms")
            }
            samples.append((ms, Self.meanLuma(shot.image), statusText(app), lockShown(app)))
        }
        let marks = ResumeFromSwitchUITests.marks(app)
        let launchProbe = app.staticTexts["debug.launch-marks"]
        let launchMarks = killed && launchProbe.exists ? launchProbe.label : ""
        if !killed, marks["cycle"] == cycle {
            for (name, value) in marks where name != "cycle" { row["mark_\(name)"] = value }
            if flow == "terminal" {
                if let sent = marks["terminal_key_sent"] { row["first_key_accepted_ms"] = sent }
                if let frame = marks["terminal_frame"] { row["link_back_ms"] = frame }
            }
        }
        func span(_ hit: ((ms: Double, luma: Double, status: String?, lock: Bool)) -> Bool) -> Double {
            guard let firstHit = samples.firstIndex(where: hit) else { return 0 }
            let lastHit = samples.lastIndex(where: hit)!
            let end = lastHit + 1 < samples.count ? samples[lastHit + 1].ms : samples[lastHit].ms
            return end - (firstHit == 0 ? 0 : samples[firstHit].ms)
        }
        row["dim_ms"] = span { beforeLuma > 1 && $0.luma < beforeLuma * 0.85 }
        row["status_ms"] = span { $0.status != nil }
        row["lock_ms"] = span { $0.lock }
        row["samples"] = Double(samples.count)
        row["luma_min"] = samples.map(\.luma).min() ?? 0
        let statuses = Array(Set(samples.compactMap(\.status))).sorted()
        let series = samples.map { String(format: "[%.0f,%.1f,%@,%ld]", $0.ms, $0.luma, Self.quoted($0.status ?? ""), $0.lock ? 1 : 0) }
            .joined(separator: ",")
        emit(flow: variant, away: away, row: row, statuses: statuses, series: series, launchMarks: launchMarks)
    }

    // MARK: Probes

    @MainActor
    private func statusText(_ app: XCUIApplication) -> String? {
        let words = ["Reattach", "Reconnect", "Connecting", "offline", "Can't connect", "unreachable"]
        let format = words.map { _ in "label CONTAINS[c] %@" }.joined(separator: " OR ")
        let match = app.staticTexts.matching(NSPredicate(format: format, argumentArray: words)).firstMatch
        return match.exists ? match.label : nil
    }

    @MainActor
    private func lockShown(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["cmuxMobile.appLock"].exists
    }

    /// Mean luma (0-255) of a 24 x 52 thumbnail.
    static func meanLuma(_ image: UIImage) -> Double {
        let width = 24, height = 52
        guard let cg = image.cgImage else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var sum = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sum += 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
        }
        return sum / Double(width * height)
    }

    // MARK: Navigation (as ResumeFromSwitchUITests)

    @MainActor
    private func open(_ id: String, in app: XCUIApplication) {
        let row = app.buttons[id]
        XCTAssertTrue(app.buttons[ResumeFromSwitchUITests.chatWorkspace].waitForExistence(timeout: 60), "the stress list\n\(app.debugDescription)")
        for _ in 0 ..< 12 where !(row.exists && row.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.exists && row.isHittable, "\(row) in the list\n\(app.debugDescription)")
        row.tap()
    }

    @MainActor
    private func openChatField(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let field = app.textViews["chat.composer.field"]
        let reply = app.buttons["agentChat.composer.collapsed"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while !field.exists, Date() < deadline {
            if reply.exists, reply.isHittable { reply.tap() }
            _ = field.waitForExistence(timeout: 0.5)
        }
        return field.exists
    }

    // MARK: Output

    private func keep(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "reattach-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func emit(flow: String, away: TimeInterval, row: [String: Double], statuses: [String], series: String,
                      launchMarks: String) {
        let body = row.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\(String(format: "%.1f", $0.value))" }.joined(separator: ",")
        let statusList = statuses.map(Self.quoted).joined(separator: ",")
        let line = #"REATTACH {"flow":"\#(flow)","away_s":\#(Int(away)),"duress":"\#(ProcessInfo.processInfo.environment["CMUX_MOBILE_DURESS_PROFILE"] ?? "see step"),"#
            + #""statuses":[\#(statusList)],"launch_marks":\#(Self.quoted(launchMarks)),\#(body),"series":[\#(series)]}"#
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.name = "reattach-\(flow)-\(Int(away))s-row"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
