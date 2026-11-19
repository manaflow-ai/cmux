import XCTest

/// Leo, 2026-11-14: connectivity should "load faster/percievably load faster". A Cloud machine
/// opened again draws the chats this run last listed on it while its channel opens, instead of
/// "Connecting to <machine> through <Mac>… Up to 40 s". The production machine screen, with the
/// chats kept in ``CloudChatsMemory`` and a channel that never answers
/// (`-cmux-mobile-recovery-gallery cloudkept`); the shots are the read-back. Before, the
/// screen had no kept chats to draw and showed the connect wait.
final class CloudChatsKeptUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAMachineOpenedAgainDrawsItsKeptChatsBeforeTheMacAnswers() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-cmux-mobile-recovery-gallery", "cloudkept"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["atlas-dev"].waitForExistence(timeout: 30), "the machine's screen\n\(app.debugDescription)")
        let newest = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Fix the flaky login test")).firstMatch
        // The channel never answers: only the kept chats can be on screen.
        XCTAssertTrue(newest.waitForExistence(timeout: 5), "the kept chats show at once\n\(app.debugDescription)")
        let connecting = app.descendants(matching: .any)["cloudChats.connecting"].firstMatch
        XCTAssertFalse(connecting.exists, "no connect wait over the kept chats")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Profile the cold start")).firstMatch.exists,
                      "every kept chat, newest first")
        attach(app, "0-kept-chats")
        // Frames while the channel is still opening: the kept list stays, with no connect wait.
        for frame in 0..<8 {
            XCTAssertFalse(connecting.exists, "no connect wait at frame \(frame)")
            XCTAssertTrue(newest.exists, "the kept chats stay at frame \(frame)")
            attach(app, String(format: "frame-%02d", frame))
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "pace")], timeout: 0.5)
        }
        // A kept chat tapped while the channel still opens: the chat's screen waits for it in place
        // (it opens once the channel is ready; CloudMachineConnectionTests runs that to a live chat).
        newest.tap()
        let opening = app.descendants(matching: .any)["cloudChats.keptOpening"].firstMatch
        XCTAssertTrue(opening.waitForExistence(timeout: 5), "the tapped kept chat waits for the channel\n\(app.debugDescription)")
        attach(app, "1-kept-chat-tapped")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
