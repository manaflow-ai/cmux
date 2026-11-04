import XCTest

/// The Chief chat, open and resting at the bottom while Chief keeps replying, keeps the
/// messages it holds loaded bounded (ConversationStore.windowTrimThreshold, 1500). The demo
/// `chief-flood` posts 32 batches of 50 replies on the mock Chief and shows the loaded count
/// over the transcript; each batch's screenshot is attached (`batch-NN`), the video proof.
final class ChiefWindowBoundUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testAnOpenChiefChatKeepsItsLoadedWindowBoundedAsRepliesArrive() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "chief-flood"]
        app.launch()

        let status = app.staticTexts["chief.flood.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 60), "the flood's status line\n\(app.debugDescription)")
        var maxLoaded = 0
        var last = ""
        for batch in 0...32 {
            let marker = NSPredicate(format: "label ENDSWITH %@", "batch \(batch)")
            let reached = expectation(for: marker, evaluatedWith: status)
            wait(for: [reached], timeout: 30)
            last = status.label
            let loaded = Self.loaded(in: last)
            maxLoaded = max(maxLoaded, loaded)
            print("CHIEF_FLOOD_UI batch=\(batch) loaded=\(loaded) label=\(last.replacingOccurrences(of: "\n", with: " | "))")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = String(format: "batch-%02d", batch)
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertTrue(last.contains("Chief replies arrived: 1600"), last)
        XCTAssertLessThanOrEqual(Self.loaded(in: last), 1500, "an open Chief chat keeps at most 1500 messages loaded: \(last)")
        print("CHIEF_FLOOD_UI final max=\(maxLoaded) last=\(last.replacingOccurrences(of: "\n", with: " | "))")
    }

    private static func loaded(in label: String) -> Int {
        guard let line = label.split(separator: "\n").first(where: { $0.hasPrefix("Messages loaded: ") }) else { return -1 }
        let digits = line.dropFirst("Messages loaded: ".count).prefix { $0.isNumber }
        return Int(digits) ?? -1
    }
}
