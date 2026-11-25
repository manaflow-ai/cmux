import QuartzCore
import XCTest

/// Leo, 2026-11-21: "when i was talkin ab the built in keyboard of ios / it's
/// like / the thing drops / the display isn't immediately motherf***ing
/// responsive."
///
/// KeyboardMotionBenchUITests' second input comes from XCUITest, whose runner
/// waits for the app to go idle before it synthesizes an event, so its time to
/// interactive carried 0.8-1.4 s of runner wait. Here XCUITest only moves the
/// keyboard (a tap on the field, the surface's hide); the second input comes
/// from inside the app (`-cmux-mobile-kbd-inject`, KeyboardInputInjector) on
/// the trace's clock:
///
/// - `slide`: a touch where the user sees the field (show) or the content
///   (hide, a short drag) at willShow/willHide + 100, 200, 300 and 900 ms, in
///   turn per direction; 80 moves each way, 20 per offset.
/// - `tti`: a key (show) or the drag (hide) on the first frame the keyboard is
///   drawn at its end; 20 moves each way.
///
/// The marks (`kbm-mark <CACurrentMediaTime> <surface> <step>`) and the trace
/// are attached as in KeyboardMotionBenchUITests; the analyzer is
/// scripts/measure/ios_keyboard_inject.py.
final class KeyboardInjectBenchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private struct Surface {
        var name: String
        var arguments: [String]
        var field: (XCUIApplication) -> XCUIElement
        var key: ((XCUIApplication) -> XCUIElement)?
        var hideByTap: ((XCUIApplication) -> Void)?
        /// Brings the field up ready for the rounds; false when it could not.
        var prepare: ((XCUIApplication) -> Bool)?
    }

    private static let base = ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-kbd-pin-trace"]

    @MainActor private static var terminal: Surface { Surface(
        name: "terminal",
        arguments: ["-cmux-mobile-demo", "ws-terminal-idle"],
        field: { $0.textViews["terminal.composer.field"] },
        key: { $0.buttons["terminal.key.keyboard"] }) }

    /// The chat opens on a question card with the composer folded into the
    /// "Reply to Claude" capsule. A tap on the capsule expands it but does not
    /// always focus the field (ComposerGrowUpUITests and
    /// TranscriptTapDismissUITests tap the field again), and an empty composer
    /// folds back on every hide: tapped once per round, the capsule brought no
    /// keyboard in 79 of 80 rounds (step cb5cfa1c). A draft keeps the field
    /// built, so every round taps the field itself, as on the other surfaces.
    @MainActor private static var chat: Surface { Surface(
        name: "chat",
        arguments: ["-cmux-mobile-demo", "kbd-chat"],
        field: { $0.textViews["chat.composer.field"] },
        // Inside the transcript's 16 pt margin: a tap at the middle of the
        // screen opened the file row under it (transport-report.html, the
        // Changes card) and left the chat (steps 9fb294f9 and cb5cfa1c).
        hideByTap: { $0.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.3)).tap() },
        prepare: { app in
            let field = app.textViews["chat.composer.field"]
            let capsule = app.descendants(matching: .any).matching(identifier: "Reply to Claude").firstMatch
            // The bench goes to the chat itself: from a diff, the Changes
            // screen or any pushed page, back until the composer shows.
            guard Self.toChat(app, field: field, capsule: capsule) else { return false }
            for _ in 0..<4 where !(field.exists && app.keyboards.firstMatch.exists) {
                if !field.exists, capsule.waitForExistence(timeout: 10) { capsule.tap() }
                guard field.waitForExistence(timeout: 5) else { continue }
                if !app.keyboards.firstMatch.exists { field.tap() }
                _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
            }
            guard field.exists, app.keyboards.firstMatch.exists else { return false }
            if !((field.value as? String) ?? "").contains(Self.draft) { field.typeText(Self.draft) }
            return ((field.value as? String) ?? "").contains(Self.draft)
        }) }

    private static let draft = "Keyboard bench draft"

    /// On the chat with its composer (folded or not); else back, up to 4
    /// screens. False, in seconds, when no composer shows.
    @MainActor
    private static func toChat(_ app: XCUIApplication, field: XCUIElement, capsule: XCUIElement) -> Bool {
        let composer = { field.exists || capsule.exists }
        let launched = Date()
        while Date().timeIntervalSince(launched) < 20 {
            if composer() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        for _ in 0..<4 {
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            let close = app.buttons["Close"].firstMatch
            if back.exists { back.tap() } else if close.exists { close.tap() } else { break }
            if capsule.waitForExistence(timeout: 3) || composer() { return true }
        }
        return composer()
    }

    @MainActor private static var chief: Surface { Surface(
        name: "chief",
        arguments: ["-cmux-mobile-demo", "chief-open"],
        field: { $0.textViews["conversation.composer.text"] },
        hideByTap: { $0.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }) }

    @MainActor func testSlideTerminal() throws { try run(Self.terminal, mode: "slide", rounds: 80) }
    @MainActor func testSlideChat() throws { try run(Self.chat, mode: "slide", rounds: 80) }
    /// Five rounds (offsets 100, 200, 300, 900, 100 ms each way): a check, in
    /// minutes of simulator time, that the bench reaches the chat and records
    /// its steps before the 80-round arms spend hours of queue.
    @MainActor func testSlideChatSmoke() throws { try run(Self.chat, mode: "slide", rounds: 5) }
    @MainActor func testSlideChief() throws { try run(Self.chief, mode: "slide", rounds: 80) }
    @MainActor func testTTITerminal() throws { try run(Self.terminal, mode: "tti", rounds: 20) }
    @MainActor func testTTIChat() throws { try run(Self.chat, mode: "tti", rounds: 20) }
    @MainActor func testTTIChief() throws { try run(Self.chief, mode: "tti", rounds: 20) }
    /// No injected input: the keyboard shows and hides 20 times each way, and
    /// the trace's per-frame content (`cb=`, `cf=`), the terminal's presents
    /// (`tp=`) and resizes (`rz=`) say when the transcript or the grid stops
    /// moving after the keyboard's last frame (scripts/measure/ios_keyboard_settle.py).
    @MainActor func testSettleChat() throws { try run(Self.chat, mode: nil, rounds: 20) }
    @MainActor func testSettleTerminal() throws { try run(Self.terminal, mode: nil, rounds: 20) }

    @MainActor func testSettleChatWithoutSampler() throws { try run(Self.chat, mode: nil, rounds: 20, sampler: .off) }
    @MainActor func testSettleTerminalWithoutSampler() throws { try run(Self.terminal, mode: nil, rounds: 20, sampler: .off) }

    @MainActor func testSettleChatAttribution() throws { try run(Self.chat, mode: nil, rounds: 20, sampler: .touch) }
    @MainActor func testSettleTerminalAttribution() throws { try run(Self.terminal, mode: nil, rounds: 20, sampler: .touch) }

    private enum Sampler { case off, hitch, touch }

    @MainActor
    private func run(_ surface: Surface, mode injected: String?, rounds: Int, sampler: Sampler = .hitch) throws {
        let mode = injected ?? "settle"
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += Self.base + surface.arguments + (injected.map { ["-cmux-mobile-kbd-inject", $0] } ?? [])
        let traceInput = injected == nil && sampler != .off
        if traceInput {
            // The baseline samples long main-loop iterations. The attribution pair
            // samples only around physical taps, at a finer cadence.
            app.launchArguments.append("-cmux-mobile-input-latency")
            if sampler == .touch { app.launchArguments.append("-cmux-mobile-input-touch-stacks") }
            app.launchEnvironment["CMUX_MOBILE_INPUT_LATENCY_MAX_STACKS"] = "50"
            app.launchEnvironment["CMUX_MOBILE_INPUT_LATENCY_MAX_FRAMES"] = "128"
        }
        app.launch()
        let probe = app.staticTexts["debug.kbd-pin"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "\(surface.name): the keyboard pin probe")
        // The trace's path, read now: a crash of the app's injected touch still leaves the file.
        let path = (probe.value as? String ?? "").split(separator: " ").first { $0.hasPrefix("file=") }
            .map { String($0.dropFirst(5)).replacingOccurrences(of: "%20", with: " ") }
        let name = "\(surface.name)-\(mode)"
        // On the surface before the first round: its field exists and, where
        // the surface needs one, the field is up with its draft.
        guard ready(surface, app, name: name, label: "setup") else {
            let bar = app.navigationBars.firstMatch
            XCTFail("\(name): no \(surface.name) composer before round 1; on \(bar.exists ? bar.identifier : "no navigation bar"), keyboard \(keyboardUp(app) ? "up" : "down")\n\(app.debugDescription)")
            attachScreen(app, "\(name)-setup")
            attachTrace(name, path, traceInput: traceInput)
            return
        }
        settle()
        var notes: [String] = []
        for round in 0..<rounds {
            // Still on the surface: a touch that opened another screen ends
            // here with a note and a way back, not in a failed tap on a field
            // that is gone (and the trace lost with it).
            if !surface.field(app).exists {
                notes.append("\(mode).show.\(round): off the surface (\(app.navigationBars.firstMatch.identifier))")
                attachScreen(app, "\(name)-off-\(round)")
                let back = app.navigationBars.buttons["BackButton"].firstMatch
                if back.exists { back.tap() }
                settle()
                guard ready(surface, app, name: name, label: "reset.\(round)") else {
                    XCTFail("\(name): left the \(surface.name) surface at round \(round) and could not return\n\(app.debugDescription)")
                    break
                }
                settle()
            }
            mark(name, "\(mode).show.\(round)")
            surface.field(app).tap()
            settle()
            if !keyboardUp(app) {
                notes.append("\(mode).show.\(round): no keyboard")
                if notes.count <= 3 { attachScreen(app, "\(name)-nokb-\(round)") }
            }
            mark(name, "\(mode).hide.\(round)")
            if let tap = surface.hideByTap { tap(app) } else { surface.key?(app).tap() }
            settle()
            if keyboardUp(app) {
                notes.append("\(mode).hide.\(round): the keyboard stayed up")
                hide(surface, app, label: "reset.hide.\(round)", name: name)
            }
        }
        mark(name, "end.end.0")
        settle(0.5)
        log("kbm-notes \(name) \(notes.isEmpty ? "-" : notes.joined(separator: "; "))")
        attachTrace(name, path, traceInput: traceInput)
    }

    /// The field exists, prepared where the surface needs it, the keyboard down.
    @MainActor
    private func ready(_ surface: Surface, _ app: XCUIApplication, name: String, label: String) -> Bool {
        if let prepare = surface.prepare {
            guard prepare(app) else { return false }
        } else {
            guard surface.field(app).waitForExistence(timeout: 30) else { return false }
        }
        if keyboardUp(app) { hide(surface, app, label: "\(label).hide.0", name: name) }
        return surface.field(app).exists
    }

    @MainActor
    private func attachScreen(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "kbm-screen-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "kbm-tree-\(name).txt"
        tree.lifetime = .keepAlways
        add(tree)
    }

    @MainActor
    private func hide(_ surface: Surface, _ app: XCUIApplication, label: String, name: String) {
        mark(name, label)
        if let key = surface.key, key(app).exists { key(app).tap() } else { surface.hideByTap?(app) }
        settle()
        if keyboardUp(app) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
            settle()
        }
    }

    @MainActor
    private func keyboardUp(_ app: XCUIApplication) -> Bool { app.keyboards.firstMatch.exists }

    /// Longer than the latest injection (900 ms after the keyboard's notification) and its drag.
    private func settle(_ seconds: TimeInterval = 1.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var logged: [String] = []

    private func log(_ line: String) {
        print(line)
        logged.append(line)
    }

    private func mark(_ name: String, _ label: String) {
        log(String(format: "kbm-mark %.6f %@ %@", CACurrentMediaTime(), name, label))
    }

    private func attachTrace(_ name: String, _ path: String?, traceInput: Bool) {
        let marks = XCTAttachment(string: logged.joined(separator: "\n") + "\n")
        marks.name = "kbm-marks-\(name).txt"
        marks.lifetime = .keepAlways
        add(marks)
        guard let path, let trace = try? String(contentsOfFile: path, encoding: .utf8) else {
            XCTFail("\(name): the trace file is unreadable (\(path ?? "no file= on the probe"))")
            return
        }
        let attachment = XCTAttachment(string: trace)
        attachment.name = "kbm-trace-\(name).txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The input latency trace sits beside the pin trace (settle runs only).
        guard traceInput else { return }
        let latency = (path as NSString).deletingLastPathComponent + "/input-latency.jsonl"
        if let lines = try? String(contentsOfFile: latency, encoding: .utf8) {
            let hitches = XCTAttachment(string: lines)
            hitches.name = "kbm-inputlat-\(name).txt"
            hitches.lifetime = .keepAlways
            add(hitches)
        }
    }
}
