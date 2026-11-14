import XCTest

/// PROTOTYPE captures: New Task's Chat/Terminal choice three ways, with separate Model, Effort
/// and Mode pickers (`TaskLaunchPrototype.swift`). Each variant at rest and with each picker
/// open, light and dark; plus a check that the pickers come back on the last picks.
final class TaskLaunchPrototypeCaptureUITests: UIStateCaptureCase {
    typealias C = UIStateCaptureCase
    private static let group = "Prototype Task Launch"
    private static let base = ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-prototype-task-launch"]

    @MainActor
    private static func opened(_ app: XCUIApplication) -> String? {
        guard any(app, "proto.prompt").waitForExistence(timeout: 20) else { return "prototype did not open" }
        let next = app.buttons["Continue"].firstMatch
        if next.waitForExistence(timeout: 1.5), next.isHittable { next.tap() }
        return nil
    }

    @MainActor
    private static func check(_ ok: @autoclosure () -> Bool, _ why: String, timeout: Double = 4) -> String? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if ok() { return nil }; pause(0.3) }
        return ok() ? nil : why
    }

    @MainActor
    private static func openMenu(_ app: XCUIApplication, _ id: String, shows item: String) -> String? {
        steps([
            { tap(any(app, id), id) },
            { check(app.buttons[item].firstMatch.exists, "the \(id) menu did not open") },
        ])
    }

    @MainActor
    private static func pickIn(_ app: XCUIApplication, _ id: String, _ item: String) -> String? {
        steps([
            { openMenu(app, id, shows: item) },
            { tap(app.buttons[item].firstMatch, item) },
            { pause(0.8); return nil },
        ])
    }

    private static func scenes(_ variant: Int, _ name: String) -> [Scene] {
        let args = base + ["-cmux-proto-reset"]
        let env = ["CMUX_PROTO_VARIANT": "\(variant)"]
        let card = variant == 3 ? ["-cmux-proto-open-card"] : []
        func scene(_ id: String, _ extra: [String] = [], _ reach: @escaping @MainActor (XCUIApplication) -> String?) -> Scene {
            Scene(group: group, id: "\(variant)-\(name)-\(id)", args: args + extra, env: env, reach: reach)
        }
        var list = [
            scene("rest") { app in opened(app) },
            scene("agent-menu", card) { app in steps([{ opened(app) }, { openMenu(app, "proto.agent", shows: "Codex") }]) },
            scene("model-menu", card) { app in steps([{ opened(app) }, { openMenu(app, "proto.model", shows: "Sonnet") }]) },
            scene("effort-menu", card) { app in steps([{ opened(app) }, { openMenu(app, "proto.effort", shows: "Max") }]) },
            scene("mode-menu", card) { app in steps([{ opened(app) }, { openMenu(app, "proto.mode", shows: "Plan") }]) },
            scene("codex", card) { app in
                steps([{ opened(app) }, { pickIn(app, "proto.agent", "Codex") },
                       { check(any(app, "proto.model").value as? String == "GPT-5.5", "Codex's model did not show") }])
            },
            scene("opencode-no-effort", card) { app in
                steps([{ opened(app) }, { pickIn(app, "proto.agent", "OpenCode") },
                       { check(!any(app, "proto.effort").exists, "OpenCode shows an effort picker") }])
            },
            scene("keyboard-down", card) { app in
                steps([{ opened(app) }, { app.swipeDown(); pause(0.5); return nil }])
            },
        ]
        switch variant {
        case 1:
            list.append(scene("terminal-chosen") { app in
                steps([{ opened(app) }, { tap(app.segmentedControls.buttons["Terminal"].firstMatch, "Terminal segment") }])
            })
            list.append(scene("chat-chosen") { app in
                steps([{ opened(app) }, { tap(app.segmentedControls.buttons["Chat"].firstMatch, "Chat segment") }])
            })
        case 2:
            list.append(scene("chat-last-used") { app in
                steps([{ opened(app) }, { tap(any(app, "proto.start.chat"), "Chat start") },
                       { tap(any(app, "proto.started.ok"), "OK") }, { pause(0.6); return nil }])
            })
        default:
            list.append(scene("card-open", card) { app in opened(app) })
        }
        list.append(scene("started", card) { app in
            steps([{ opened(app) }, { tap(any(app, variant == 2 ? "proto.start.terminal" : "proto.start"), "Start") },
                   { check(any(app, "proto.started").exists, "no started note") }])
        })
        return list
    }

    @MainActor
    func testTaskLaunchPrototypeStates() {
        capture(Self.scenes(1, "top-switch") + Self.scenes(2, "two-starts") + Self.scenes(3, "setup-card"))
    }

    /// Default = the last pick: an agent's model, effort and mode, and Chat or Terminal, come back
    /// after a relaunch, in another variant too (they share the picks).
    @MainActor
    func testPickersComeBackOnTheLastPicks() {
        XCUIDevice.shared.appearance = .light
        var app = launch(variant: 1, reset: true)
        XCTAssertNil(Self.opened(app))
        XCTAssertNil(Self.pickIn(app, "proto.agent", "Codex"))
        XCTAssertNil(Self.pickIn(app, "proto.effort", "High"))
        XCTAssertNil(Self.pickIn(app, "proto.mode", "Read only"))
        XCTAssertNil(Self.tap(app.segmentedControls.buttons["Chat"].firstMatch, "Chat segment"))
        // Picked on screen first, then time for the defaults write to land before the kill.
        XCTAssertEqual(Self.any(app, "proto.agent").value as? String, "Codex")
        XCTAssertEqual(Self.any(app, "proto.mode").value as? String, "Read only")
        Self.pause(3)
        app.terminate()

        app = launch(variant: 3, reset: false, open: true)
        XCTAssertNil(Self.opened(app))
        XCTAssertEqual(Self.any(app, "proto.agent").value as? String, "Codex")
        XCTAssertEqual(Self.any(app, "proto.effort").value as? String, "High")
        XCTAssertEqual(Self.any(app, "proto.mode").value as? String, "Read only")
        XCTAssertEqual(app.segmentedControls.buttons["Chat"].firstMatch.isSelected, true)
        // Claude keeps its own picks: switching back shows its defaults, not Codex's.
        XCTAssertNil(Self.pickIn(app, "proto.agent", "Claude Code"))
        XCTAssertEqual(Self.any(app, "proto.mode").value as? String, "Ask before edits")
        app.terminate()
    }

    @MainActor
    private func launch(variant: Int, reset: Bool, open: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_PROTO_VARIANT"] = "\(variant)"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmuxMobile.settings.appearance", "light"] + Self.base
        if reset { app.launchArguments.append("-cmux-proto-reset") }
        if open { app.launchArguments.append("-cmux-proto-open-card") }
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 20)
        Self.pause(2.5)
        pickTeamIfAsked(app)
        return app
    }
}
