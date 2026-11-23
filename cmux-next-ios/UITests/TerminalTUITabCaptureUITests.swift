import XCTest

/// A full-screen app in a workspace tab starts inside the terminal area
/// (fleet capture on feat-cmux-next 4f10aea6625b: the Mac's 30x12 grid in a
/// tab had its top border and first rows under the status bar). The
/// terminal demo's host grid session (mock data, no Mac) in a tab and
/// standalone, light and dark; every state is attached as a screenshot, and
/// the page's layout (`debugState`, in the demo's step label) is checked:
/// the TUI host starts inside its clip and Ghostty draws its grid at the
/// host's top.
final class TerminalTUITabCaptureUITests: XCTestCase {
    struct Scene {
        var id: String
        var embedded: Bool
    }

    static let scenes = [
        Scene(id: "tui-30x12-tab", embedded: true),
        Scene(id: "tui-30x12", embedded: false),
    ]

    override func setUp() {
        continueAfterFailure = true
    }

    /// `key=<a>-<b>` or `key=<a>+<b>` or `key=<a>` in the step label.
    static func numbers(_ label: String, _ key: String) -> [Int] {
        guard let range = label.range(of: " \(key)=") else { return [] }
        let rest = label[range.upperBound...].prefix { !$0.isWhitespace }
        return rest.split(whereSeparator: { $0 == "-" || $0 == "+" }).compactMap { Int($0) }
    }

    @MainActor
    func testFullScreenAppStartsInsideTheTerminalArea() throws {
        var problems: [String] = []
        for scene in Self.scenes {
            for look in ["light", "dark"] {
                XCUIDevice.shared.appearance = look == "dark" ? .dark : .light
                XCUIDevice.shared.orientation = .portrait
                let app = XCUIApplication()
                app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
                app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmuxMobile.settings.appearance", look,
                                        "-CmuxMobileTerminalDemo", "-CmuxMobileHostGridDemo", "30x12,tui"]
                if scene.embedded { app.launchArguments.append("-CmuxMobileTerminalDemoEmbedded") }
                app.launch()
                let probe = app.staticTexts["debug.terminal-demo"]
                XCTAssertTrue(probe.waitForExistence(timeout: 30), "\(scene.id): the terminal demo did not open")
                // The demo has no signal for its last frame; its label updates
                // every 0.25 s for 5 s.
                RunLoop.current.run(until: Date().addingTimeInterval(3))
                let label = probe.label
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "tuitab~~\(scene.id)~~\(look)"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTContext.runActivity(named: "\(scene.id)/\(look): \(label)") { _ in }
                print("tui-tab \(scene.id)/\(look): \(label)")
                let clip = Self.numbers(label, "tuiclip"), host = Self.numbers(label, "tuihost")
                let surfaceY = Self.numbers(label, "surface.y")
                if clip.count != 2 || host.count != 2 || surfaceY.count != 1 {
                    problems.append("\(scene.id)/\(look): no layout in \"\(label)\"")
                } else {
                    if host[0] < clip[0] { problems.append("\(scene.id)/\(look): TUI host starts \(clip[0] - host[0]) pt above its clip (\(label))") }
                    if host[0] + host[1] > clip[1] + 1 { problems.append("\(scene.id)/\(look): TUI host ends under the composer (\(label))") }
                    if surfaceY[0] != 0 { problems.append("\(scene.id)/\(look): the grid is drawn \(-surfaceY[0]) pt above the host's top (\(label))") }
                }
                app.terminate()
            }
        }
        XCTAssertTrue(problems.isEmpty, "\(problems)")
    }
}
