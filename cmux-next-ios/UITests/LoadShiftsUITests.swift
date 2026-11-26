import XCTest

/// Leo, 2026-11-24: "the loading has layout shifts and placeholder states that likely dont need to
/// be so placeholder and better diffed. i think diffing better in ios for ui stuff may help perf
/// and percievef speed/percieved speed to interactivity on ios."
///
/// One harness for before and after: every load Leo goes through (launch to the list, opening an
/// agent workspace, opening a terminal workspace, relaunching back into the last workspace), each
/// sampled with `app.snapshot()` from the action on, about every 0.1 s for 4 s:
/// - `tti_ms`: action to the target (the row, the composer) on screen and hittable.
/// - `shifts`: after the target is ready, how many times an element already on screen (same
///   type, identifier and label) moved more than 2 pt or resized; a page that is laid out
///   once and filled in place reads 0.
/// - `placeholder_samples`: samples showing a loading placeholder (a "Loading…", "Waiting…" or
///   "Connecting…" line, or `workspaces.loading`).
/// Each flow prints one `LOADSHIFTS {json}` line and attaches it.
final class LoadShiftsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testLoadsLayOutOnceAndAreQuickToInteract() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        let base = ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "workspaces"]

        // 1. Launch to the Workspaces list.
        app.launchArguments = base + ["-cmux-mobile-no-restore"]
        var results: [Result] = []
        results.append(measure(app, "launch-list", target: { $0.buttons["workspace.row.ws-cmux"].firstMatch }) { app.launch() })

        // 2. Open an agent workspace (its chat).
        results.append(measure(app, "open-agent-workspace", target: Self.anyComposer) {
            app.buttons["workspace.row.ws-cmux"].firstMatch.tap()
        })
        back(app)

        // 3. Open a terminal workspace.
        let row = app.buttons["workspace.row.ws-ios"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "ws-ios row")
        results.append(measure(app, "open-terminal-workspace", target: { $0.textViews["terminal.composer.field"].firstMatch }) {
            row.tap()
        })
        pause(2.0)

        // 4. Relaunch: back into the last workspace (restored), its cached page.
        app.terminate()
        app.launchArguments = base
        results.append(measure(app, "relaunch-into-terminal", target: { $0.textViews["terminal.composer.field"].firstMatch }) {
            app.launch()
        })
        app.terminate()

        let summary = results.map(\.line).joined(separator: "\n")
        print(summary)
        let attachment = XCTAttachment(string: summary)
        attachment.name = "LOADSHIFTS"
        attachment.lifetime = .keepAlways
        add(attachment)
        for result in results { XCTAssertNotNil(result.ttiMs, "\(result.flow): the target never became interactive") }
    }

    struct Result {
        var flow: String
        var ttiMs: Int?
        var shifts: Int
        var placeholderSamples: Int
        var samples: Int
        var moved: [String]

        var line: String {
            let json: [String: Any] = ["flow": flow, "tti_ms": ttiMs ?? -1, "shifts": shifts,
                                       "placeholder_samples": placeholderSamples, "samples": samples,
                                       "moved": Array(moved.prefix(8))]
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
            return "LOADSHIFTS " + (String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    static let anyComposer: (XCUIApplication) -> XCUIElement = { app in
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["chat.composer.field", "chat.composer.card", "conversation.composer.text", "terminal.composer.field"]
        )).firstMatch
    }

    @MainActor
    func measure(_ app: XCUIApplication, _ flow: String, target: (XCUIApplication) -> XCUIElement,
                 action: () -> Void) -> Result {
        let start = Date()
        action()
        var ready: Date?
        var last: [String: CGRect] = [:]
        var shifts = 0
        var placeholders = 0
        var samples = 0
        var moved: [String] = []
        var shot = 0
        while Date().timeIntervalSince(start) < 4.0 || ready == nil && Date().timeIntervalSince(start) < 30 {
            guard let root = try? app.snapshot() else { pause(0.05); continue }
            samples += 1
            var now: [String: CGRect] = [:]
            var placeholder = false
            collect(root, into: &now, placeholder: &placeholder)
            if placeholder { placeholders += 1 }
            if ready == nil {
                let element = target(app)
                if element.exists, element.isHittable {
                    ready = Date()
                }
            } else {
                for (key, frame) in now {
                    guard let before = last[key] else { continue }
                    if abs(before.minY - frame.minY) > 2 || abs(before.minX - frame.minX) > 2 || abs(before.height - frame.height) > 2 {
                        shifts += 1
                        moved.append("\(key) \(Int(before.minY))->\(Int(frame.minY))")
                    }
                }
            }
            if ready != nil || shot < 4 {
                if shot < 6 {
                    let attachment = XCTAttachment(screenshot: app.screenshot())
                    attachment.name = "\(flow)-\(shot)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    shot += 1
                }
            }
            last = ready == nil ? [:] : now
            pause(0.1)
        }
        return Result(flow: flow, ttiMs: ready.map { Int($0.timeIntervalSince(start) * 1000) }, shifts: shifts,
                      placeholderSamples: placeholders, samples: samples, moved: moved)
    }

    /// Leaf elements with a name, keyed by type, identifier and label; inside the window only.
    func collect(_ element: XCUIElementSnapshot, into map: inout [String: CGRect], placeholder: inout Bool) {
        let label = element.label
        if element.identifier == "workspaces.loading" || label.hasPrefix("Loading") || label.hasPrefix("Waiting for")
            || label.hasPrefix("Connecting") {
            placeholder = true
        }
        if element.children.isEmpty, !(element.identifier.isEmpty && label.isEmpty), !element.frame.isEmpty {
            let key = "\(element.elementType.rawValue)|\(element.identifier)|\(label.prefix(40))"
            // Repeated keys (identical rows) are ambiguous: drop them.
            if map[key] != nil { map[key] = .null } else { map[key] = element.frame }
        }
        for child in element.children { collect(child, into: &map, placeholder: &placeholder) }
        map = map.filter { !$0.value.isNull }
    }

    @MainActor
    func back(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        pause(1.5)
    }

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
