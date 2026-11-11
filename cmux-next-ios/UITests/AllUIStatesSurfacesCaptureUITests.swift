import XCTest

/// All-UI-states capture, part 4: terminal, browser, Screen Sharing, diff,
/// artifacts and file previews. See `UIStateCapture.swift`.
final class AllUIStatesSurfacesCaptureUITests: UIStateCaptureCase {
    typealias C = UIStateCaptureCase
    private static let idle = ["-cmux-mobile-demo", "ws-terminal-idle"]

    @MainActor
    func testTerminal() {
        let g = "7 Terminal"
        capture([
            Scene(group: g, id: "idle-keyboard-down", args: Self.idle, settle: 6),
            Scene(group: g, id: "keyboard-up-armed-draft", args: ["-cmux-mobile-demo", "ws-terminal-armed"], settle: 7),
            Scene(group: g, id: "composer-open", args: Self.idle, settle: 6) { app in C.tap(app.buttons["terminal.key.composer"], "composer key") },
            Scene(group: g, id: "keyboard-up-empty", args: Self.idle, settle: 6) { app in
                C.showKeyboard(app, field: app.textViews["terminal.composer.field"], "terminal composer")
            },
            Scene(group: g, id: "control-locked", args: Self.idle, settle: 6) { app in
                let control = app.buttons["terminal.key.control"]
                guard control.waitForExistence(timeout: 10) else { return "no control key" }
                control.tap(); control.tap()
                return nil
            },
            Scene(group: g, id: "key-row-scrolled", args: Self.idle, settle: 6) { app in
                let row = app.buttons["terminal.key.escape"]
                guard row.waitForExistence(timeout: 10) else { return "no key row" }
                row.swipeLeft()
                return nil
            },
            Scene(group: g, id: "joystick", args: Self.idle, settle: 6) { app in
                let arrow = C.any(app, "terminal.key.up")
                guard arrow.waitForExistence(timeout: 10) else { return "no arrow key" }
                arrow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 1.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7)))
                return nil
            },
            Scene(group: g, id: "send-menu", args: ["-cmux-mobile-demo", "ws-terminal-armed"], settle: 7) { app in
                C.longPress(app.buttons["terminal.composer.send"], "Send")
            },
            Scene(group: g, id: "attach-menu", args: ["-cmux-mobile-demo", "ws-terminal-armed"], settle: 7) { app in
                C.tap(C.any(app, "terminal.composer.attach"), "attach")
            },
            Scene(group: g, id: "voice-button-agent-running", args: ["-cmux-mobile-demo", "voice-terminal"], settle: 6),
            Scene(group: g, id: "voice-mode-terminal", args: ["-cmux-mobile-demo", "voice-terminal"],
                  env: ["CMUX_MOBILE_VOICE_MODE_DEMO": "1", "CMUX_MOBILE_VOICE_MODE_DEMO_PROMPT": "list the files"], settle: 6) { app in
                C.steps([{ C.tap(app.buttons["terminal.composer.voice"], "voice button") }, { C.wait(app.staticTexts["voiceMode.caption"].firstMatch, "voice caption", timeout: 10) }])
            },
            Scene(group: g, id: "scrolled-back-jump", args: Self.idle, settle: 6) { app in
                for _ in 0..<3 {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                        .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
                }
                return nil
            },
            Scene(group: g, id: "copy-mode", args: Self.idle, settle: 6) { app in
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).press(forDuration: 1.2)
                return nil
            },
            Scene(group: g, id: "page-menu", args: Self.idle, settle: 6) { app in C.tap(app.buttons["Page Menu"].firstMatch, "Page Menu") },
            Scene(group: g, id: "terminal-tour", args: ["-cmux-mobile-demo", "ws-terminal"], settle: 0,
                  frames: [("typing", 6), ("sent", 9), ("htop-tui", 14), ("grid", 20), ("files-and-links", 30)]),
            Scene(group: g, id: "connecting", args: ["-cmux-mobile-demo", "retry-terminal"], settle: 4),
            Scene(group: g, id: "offline-retry", args: ["-cmux-mobile-recovery-gallery", "terminal"], settle: 3),
            Scene(group: g, id: "fake-codex-running", args: Self.idle + ["-cmux-mobile-term-fake-codex"], settle: 7),
            Scene(group: g, id: "standalone-terminal", args: ["-CmuxMobileTerminalDemo"], settle: 5),
            Scene(group: g, id: "standalone-more-menu", args: ["-CmuxMobileTerminalDemo"], settle: 5) { app in C.tap(C.any(app, "terminal.more"), "More") },
            Scene(group: g, id: "demo-tui", args: ["-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoPhases", "tui"], settle: 9),
            Scene(group: g, id: "demo-vim", args: ["-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoPhases", "vim"], settle: 9),
            Scene(group: g, id: "demo-attachments", args: ["-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoPhases", "attachments"], settle: 9),
            Scene(group: g, id: "demo-artifacts", args: ["-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoPhases", "artifacts"], settle: 9),
            Scene(group: g, id: "demo-keyboard", args: ["-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoPhases", "keyboard"], settle: 9),
        ])
    }

    @MainActor
    func testBrowserAndScreenSharing() {
        let g = "8 Browser"
        var scenes: [Scene] = []
        for scene in ["empty", "context", "select", "dialog", "confirm", "prompt", "page-menu"] {
            scenes.append(Scene(group: g, id: "streamed-\(scene)", args: ["-cmux-mobile-browser-events", scene], settle: 5))
        }
        scenes += [
            Scene(group: g, id: "streamed-meter", args: ["-cmux-mobile-browser-events", "empty", "-cmux-mobile-browser-meter"], settle: 5),
            Scene(group: g, id: "streamed-keyboard", args: ["-cmux-mobile-browser-events", "empty"], settle: 5) { app in
                C.tap(C.any(app, "browser.keyboard"), "browser keyboard button")
            },
            Scene(group: g, id: "address-editing", args: ["-cmux-mobile-browser-events", "empty"], settle: 5) { app in
                C.tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Address' OR label BEGINSWITH 'Show toolbar'")).firstMatch, "address bar")
            },
            Scene(group: g, id: "mock-browser-tab", args: ["-cmux-mobile-tab", "workspaces"]) { app in
                C.steps([
                    { C.tap(app.buttons["workspace.row.ws-cmux"], "ws-cmux row") },
                    { C.pause(1.5); return C.tap(app.buttons["Tabs"].firstMatch, "Tabs") },
                    { C.tap(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'docs' AND label ENDSWITH ', tab'")).firstMatch, "docs card") },
                ])
            },
        ]
        let s = "9 Screen Sharing"
        scenes += [
            Scene(group: s, id: "settings-finding-macs", args: ["-cmux-mobile-settings-page", "screenSharing"], settle: 1.5),
            Scene(group: s, id: "settings-after-wait", args: ["-cmux-mobile-settings-page", "screenSharing"], settle: 12),
            Scene(group: s, id: "viewer-streaming", args: ["-CmuxMobileScreenSharingDemo", "-cmux-mobile-no-restore"], signedIn: false, settle: 6),
            Scene(group: s, id: "viewer-trackpad", args: ["-CmuxMobileScreenSharingDemo", "-cmux-mobile-no-restore"], signedIn: false, settle: 6) { app in
                C.tap(app.buttons["screen.trackpad.show"], "Trackpad button")
            },
            Scene(group: s, id: "viewer-trackpad-options", args: ["-CmuxMobileScreenSharingDemo", "-cmux-mobile-no-restore"], signedIn: false, settle: 6) { app in
                C.steps([{ C.tap(app.buttons["screen.trackpad.show"], "Trackpad button") }, { C.tap(app.otherElements["screen.trackpad.overlay"].buttons["screen.options"], "overlay options") }])
            },
            Scene(group: s, id: "viewer-keyboard", args: ["-CmuxMobileScreenSharingDemo", "-cmux-mobile-no-restore"], signedIn: false, settle: 6) { app in
                C.tap(app.buttons["Keyboard"].firstMatch, "Keyboard button")
            },
            Scene(group: s, id: "viewer-landscape", args: ["-CmuxMobileScreenSharingDemo", "-cmux-mobile-no-restore"], signedIn: false, settle: 6) { _ in
                XCUIDevice.shared.orientation = .landscapeLeft
                C.pause(1.5)
                return nil
            },
        ]
        capture(scenes)
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testDiffAndArtifacts() {
        let g = "10 Diff, artifacts and file preview"
        let diff = ["CMUX_MOBILE_LIST_SCREEN": "diff", "CMUX_MOBILE_LIST_COUNT": "3", "CMUX_MOBILE_LIST_PASSES": "0"]
        capture([
            Scene(group: g, id: "diff-unified", env: diff, settle: 5),
            Scene(group: g, id: "diff-split", env: diff.merging(["CMUX_MOBILE_LIST_SPLIT": "1"]) { $1 }, settle: 5),
            Scene(group: g, id: "diff-wrap", env: diff.merging(["CMUX_MOBILE_LIST_WRAP": "1"]) { $1 }, settle: 5),
            Scene(group: g, id: "diff-line-menu", env: diff, settle: 5) { app in
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 1.2)
                return nil
            },
            Scene(group: g, id: "diff-from-chat", args: ["-CmuxMobileDemo", "chat-feed", "-CmuxMobileDemoHold", "diff"], settle: 30),
            Scene(group: g, id: "artifacts-list", env: ["CMUX_MOBILE_LIST_SCREEN": "artifacts", "CMUX_MOBILE_LIST_COUNT": "40", "CMUX_MOBILE_LIST_PASSES": "0"], settle: 5),
            Scene(group: g, id: "artifacts-grid", env: ["CMUX_MOBILE_LIST_SCREEN": "artifacts", "CMUX_MOBILE_LIST_COUNT": "40", "CMUX_MOBILE_LIST_PASSES": "0"], settle: 5) { app in
                C.tap(C.any(app, "artifacts.layout"), "layout toggle")
            },
            Scene(group: g, id: "artifacts-context-menu", env: ["CMUX_MOBILE_LIST_SCREEN": "artifacts", "CMUX_MOBILE_LIST_COUNT": "40", "CMUX_MOBILE_LIST_PASSES": "0"], settle: 5) { app in
                C.longPress(app.cells.element(boundBy: 1), "an artifact row")
            },
            Scene(group: g, id: "artifact-preview", env: ["CMUX_MOBILE_LIST_SCREEN": "artifacts", "CMUX_MOBILE_LIST_COUNT": "40", "CMUX_MOBILE_LIST_PASSES": "0"], settle: 5) { app in
                C.tap(app.cells.element(boundBy: 1), "an artifact row")
            },
            Scene(group: g, id: "artifacts-parity-demo", args: ["-CmuxMobileDemo", "acp-parity", "-CmuxMobileDemoPhases", "artifacts"], settle: 0,
                  frames: [("parity-artifacts", 8), ("parity-artifact-open", 14)]),
            Scene(group: g, id: "image-zoom", args: ["-CmuxMobileDemo", "acp-parity", "-CmuxMobileDemoPhases", "artifacts", "-cmux-mobile-image-zoom-demo"], settle: 16),
            Scene(group: g, id: "large-preview", args: ["-cmux-mobile-demo", "large-preview"], settle: 8),
            Scene(group: g, id: "large-preview-low-space", args: ["-cmux-mobile-demo", "large-preview-low-space"], settle: 8),
        ])
    }
}
