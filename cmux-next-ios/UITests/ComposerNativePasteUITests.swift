import UIKit
import UniformTypeIdentifiers
import XCTest

/// The composers paste like any iOS text field: the edit menu's Paste (tap
/// the focused field) puts copied text in the field, and Paste of a copied
/// image, or of a file copied in Files, attaches it. Command-V calls the same
/// `paste(_:)`; a headless simulator drops Command chords, so it is not driven
/// here. Runs the Chief chat, an empty agent chat and a workspace's terminal
/// tab with mock sign-in and mock sessions. The test runner fills the
/// pasteboard, as another app would.
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
        try checkPaste(demo: "kbd-chat-empty", field: "chat.composer.field", attachment: "attachment.thumb", expand: "Reply to Claude")
    }

    @MainActor
    func testChiefComposerPastes() throws {
        try checkPaste(demo: "chief-open", field: "conversation.composer.text", attachment: "conversation.composer.attachment")
    }

    @MainActor
    private func checkPaste(demo: String, field id: String, attachment: String, expand: String? = nil) throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo]
        app.launch()

        // The agent chat shows its composer collapsed until tapped.
        if let expand {
            let bar = app.buttons[expand]
            XCTAssertTrue(bar.waitForExistence(timeout: 20), "\(expand)\n\(app.debugDescription)")
            bar.tap()
        }
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

        // A copied image: Paste is offered and attaches it; the text stays.
        UIPasteboard.general.image = Self.sampleImage()
        try menuPaste(app, field)
        XCTAssertTrue(app.descendants(matching: .any)[attachment].waitForExistence(timeout: 5),
                      "pasted image attached\n\(app.debugDescription)")
        XCTAssertTrue(waitForValue(field, containing: "echo menu-paste"), "the draft text is kept")
        attach(app, "\(demo)-image-paste")

        // A file copied in Files, as Files puts it (seen on iOS 26.5): its own
        // private type first, then the file's type and bytes, no path.
        // An item provider keeps that order (a dictionary of types does not).
        let pdf = Self.samplePDF()
        let provider = NSItemProvider()
        provider.suggestedName = "Quarterly Report.pdf"
        for type in ["com.apple.DocumentManager.FINode.File", UTType.pdf.identifier] {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                completion(pdf, nil)
                return nil
            }
        }
        UIPasteboard.general.setItemProviders([provider], localOnly: false, expirationDate: nil)
        try menuPaste(app, field)
        let tiles = app.descendants(matching: .any).matching(identifier: attachment)
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 2"), object: tiles)], timeout: 5) == .completed,
                      "pasted file attached\n\(app.debugDescription)")
        XCTAssertTrue(waitForValue(field, containing: "echo menu-paste"), "the draft text is kept")
        attach(app, "\(demo)-file-paste")
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
    private static func samplePDF() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            ("Quarterly Report" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 28)])
        }
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
