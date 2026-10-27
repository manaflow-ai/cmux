import UIKit
import XCTest

/// The composers paste like any iOS text field: the edit menu's Paste (tap
/// the focused field) and Command-V on a hardware keyboard put copied text
/// in the field, and a copied image becomes an attachment of the composer
/// that takes attachments. Runs the Chief chat, an empty agent chat and a
/// workspace's terminal tab with mock sign-in and mock sessions. The test
/// runner fills the pasteboard, as another app would.
final class ComposerNativePasteUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTerminalComposerPastes() throws {
        try checkPaste(demo: "ws-terminal-idle", field: "terminal.composer.field", attachment: "terminal.attachment")
    }

    @MainActor
    func testAgentChatComposerPastes() throws {
        try checkPaste(demo: "kbd-chat-empty", field: "chat.composer.field", attachment: "attachment.thumb")
    }

    @MainActor
    func testChiefComposerPastes() throws {
        try checkPaste(demo: "chief-open", field: "conversation.composer.text", attachment: "conversation.composer.attachment")
    }

    @MainActor
    private func checkPaste(demo: String, field id: String, attachment: String) throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo]
        app.launch()

        let field = app.textViews[id]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "\(id)\n\(app.debugDescription)")
        // The field can appear while its screen is still pushing: tap until it has focus.
        for _ in 0..<5 where !hasFocus(field) {
            field.tap()
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)], timeout: 2)
        }
        XCTAssertTrue(hasFocus(field), "the field takes focus\n\(app.debugDescription)")

        // The edit menu's Paste: text goes into the field.
        UIPasteboard.general.string = "echo menu-paste"
        try menuPaste(app, field)
        XCTAssertTrue(waitForValue(field, containing: "echo menu-paste"), "edit menu Paste\n\(String(describing: field.value))")
        attach(app, "\(demo)-menu-paste")

        // Command-V on a hardware keyboard.
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        UIPasteboard.general.string = "echo command-v"
        field.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitForValue(field, containing: "echo command-v"), "Command-V\n\(String(describing: field.value))")
        attach(app, "\(demo)-command-v")

        // A copied image: Paste is offered and attaches it; the text stays.
        UIPasteboard.general.image = Self.sampleImage()
        try menuPaste(app, field)
        XCTAssertTrue(app.descendants(matching: .any)[attachment].waitForExistence(timeout: 5),
                      "pasted image attached\n\(app.debugDescription)")
        XCTAssertTrue(waitForValue(field, containing: "echo command-v"), "the draft text is kept")
        attach(app, "\(demo)-image-paste")
    }

    /// Taps the focused field for its edit menu and picks Paste.
    @MainActor
    private func menuPaste(_ app: XCUIApplication, _ field: XCUIElement) throws {
        field.tap()
        let item = app.menuItems["Paste"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the edit menu offers Paste\n\(app.debugDescription)")
        item.tap()
    }

    @MainActor
    private func hasFocus(_ field: XCUIElement) -> Bool {
        (field.value(forKey: "hasKeyboardFocus") as? Bool) == true
    }

    @MainActor
    private func waitForValue(_ field: XCUIElement, containing text: String) -> Bool {
        let predicate = NSPredicate { object, _ in
            ((object as? XCUIElement)?.value as? String)?.contains(text) == true
        }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: field)], timeout: 5) == .completed
    }

    @MainActor
    private static func sampleImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            UIColor.white.setFill()
            context.fill(CGRect(x: 20, y: 20, width: 80, height: 40))
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
