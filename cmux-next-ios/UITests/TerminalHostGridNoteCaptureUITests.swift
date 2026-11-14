import XCTest

/// Live report (2026-11-12): with the shared grid set to 30×12 by another
/// device (Fit the smallest viewer), a shell and `top` on the phone's
/// primary screen sat at the bottom of the page, on the composer, with no
/// letterbox and no note. The grid now pins to the top with the one-line
/// note `30×12 · set by Rig Mac` in the space below it, on the primary
/// screen and in a full-screen app; a grid that fills the page gets the
/// compact `120×60` chip in its top-trailing corner
/// (docs/shared-terminal-sizing.md "Showing the bounds").
///
/// The terminal demo's host grid session (`-CmuxMobileHostGridDemo`, mock
/// data, no Mac) in light and dark, standalone and in a workspace tab, with
/// the keyboard down and up. Every state is attached as a screenshot; the
/// note is then checked by its accessibility identifier.
final class TerminalHostGridNoteCaptureUITests: XCTestCase {
    struct Scene {
        var id: String
        var spec: String
        var embedded = false
        var keyboard = false
        /// The note's accessibility label (nil: none expected).
        var note: String?
    }

    static let scenes: [Scene] = [
        Scene(id: "shell-30x12", spec: "30x12", note: "30×12 · set by Rig Mac"),
        Scene(id: "shell-30x12-keyboard", spec: "30x12", keyboard: true, note: "30×12 · set by Rig Mac"),
        Scene(id: "shell-30x12-tab", spec: "30x12", embedded: true, note: "30×12 · set by Rig Mac"),
        Scene(id: "tui-30x12", spec: "30x12,tui", note: "30×12 · set by Rig Mac"),
        // The grid and its note fit above the keyboard: both stay whole at the top.
        Scene(id: "tui-30x12-keyboard", spec: "30x12,tui", keyboard: true, note: "30×12 · set by Rig Mac"),
        Scene(id: "tui-30x12-tab", spec: "30x12,tui", embedded: true, note: "30×12 · set by Rig Mac"),
        Scene(id: "shell-120x60", spec: "120x60", note: "120×60 · set by Rig Mac"),
        Scene(id: "tui-120x60", spec: "120x60,tui", note: "120×60 · set by Rig Mac"),
    ]

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testHostGridNoteInEveryState() throws {
        var missing: [String] = []
        for scene in Self.scenes {
            for look in ["light", "dark"] {
                XCUIDevice.shared.appearance = look == "dark" ? .dark : .light
                XCUIDevice.shared.orientation = .portrait
                let app = XCUIApplication()
                app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
                app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmuxMobile.settings.appearance", look,
                                        "-CmuxMobileTerminalDemo", "-CmuxMobileHostGridDemo", scene.spec]
                if scene.embedded { app.launchArguments.append("-CmuxMobileTerminalDemoEmbedded") }
                app.launch()
                let probe = app.staticTexts["debug.terminal-demo"]
                XCTAssertTrue(probe.waitForExistence(timeout: 30), "\(scene.id): the terminal demo did not open")
                if scene.keyboard {
                    let key = app.buttons["terminal.key.keyboard"]
                    if key.waitForExistence(timeout: 5) { key.tap() }
                }
                // The demo's output and frames land; it has no signal to wait on.
                RunLoop.current.run(until: Date().addingTimeInterval(scene.keyboard ? 2.5 : 1.5))
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "hostgrid~~\(scene.id)~~\(look)"
                attachment.lifetime = .keepAlways
                add(attachment)
                if let note = scene.note {
                    let element = app.descendants(matching: .any)["terminal.hostGridNote"]
                    if !element.exists || element.label != note {
                        missing.append("\(scene.id)/\(look): \(element.exists ? "label \"\(element.label)\"" : "no note")")
                    }
                }
                app.terminate()
            }
        }
        print("host-grid-note missing: \(missing)")
        XCTAssertTrue(missing.isEmpty, "states without the expected note: \(missing)")
    }
}
