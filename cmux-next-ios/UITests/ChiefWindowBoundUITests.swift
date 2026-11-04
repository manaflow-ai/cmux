import XCTest

/// The Chief chat, open and resting at the bottom while Chief keeps replying, keeps the
/// messages it holds loaded bounded (ConversationStore.windowTrimThreshold, 1500). The demo
/// `chief-flood` posts 72 batches of 50 replies on the mock Chief and shows the loaded count
/// over the transcript; the test attaches a screenshot each time the batch changes
/// (`batch-NN`), the video proof.
final class ChiefWindowBoundUITests: XCTestCase {
    private static let batches = 72

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
        var lastBatch = -1
        var last = ""
        let deadline = Date().addingTimeInterval(600)
        // Each label read is a round trip to the app; the demo holds each batch 1.2 s.
        while lastBatch < Self.batches, Date() < deadline {
            last = status.label
            let batch = Self.number(after: "batch ", in: last)
            guard batch != lastBatch, batch >= 0 else { continue }
            lastBatch = batch
            let loaded = Self.number(after: "Messages loaded: ", in: last)
            maxLoaded = max(maxLoaded, loaded)
            print("CHIEF_FLOOD_UI batch=\(batch) loaded=\(loaded) label=\(last.replacingOccurrences(of: "\n", with: " | "))")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = String(format: "batch-%02d", batch)
            shot.lifetime = .keepAlways
            add(shot)
        }
        print("CHIEF_FLOOD_UI final max=\(maxLoaded) last=\(last.replacingOccurrences(of: "\n", with: " | "))")
        XCTAssertEqual(lastBatch, Self.batches, "the flood finished: \(last)")
        XCTAssertTrue(last.contains("Chief replies arrived: \(Self.batches * 50)"), last)
        XCTAssertLessThanOrEqual(maxLoaded, 1500, "an open Chief chat keeps at most 1500 messages loaded; it reached \(maxLoaded)")
    }

    private static func number(after prefix: String, in label: String) -> Int {
        guard let line = label.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return -1 }
        return Int(line.dropFirst(prefix.count).prefix { $0.isNumber }) ?? -1
    }
}
