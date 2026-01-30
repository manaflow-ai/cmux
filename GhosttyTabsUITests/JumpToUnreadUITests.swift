import XCTest
import Foundation

final class JumpToUnreadUITests: XCTestCase {
    private var dataPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-jump-unread-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
    }

    func testJumpToUnreadFocusesPanelAcrossTabs() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_JUMP_UNREAD_PATH"] = dataPath
        app.launch()
        app.activate()

        XCTAssertTrue(
            waitForJumpUnreadData(keys: ["expectedTabId", "expectedSurfaceId"], timeout: 6.0),
            "Expected test setup data to be written"
        )

        guard let setupData = loadJumpUnreadData() else {
            XCTFail("Missing test setup data")
            return
        }

        let expectedTabId = setupData["expectedTabId"]
        let expectedSurfaceId = setupData["expectedSurfaceId"]
        XCTAssertNotNil(expectedTabId)
        XCTAssertNotNil(expectedSurfaceId)

        app.typeKey("u", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForJumpUnreadData(keys: ["focusedTabId", "focusedSurfaceId"], timeout: 6.0),
            "Expected jump-to-unread focus to be recorded"
        )

        guard let focusedData = loadJumpUnreadData() else {
            XCTFail("Missing jump-to-unread focus data")
            return
        }

        XCTAssertEqual(focusedData["focusedTabId"], expectedTabId)
        XCTAssertEqual(focusedData["focusedSurfaceId"], expectedSurfaceId)
    }

    private func waitForJumpUnreadData(keys: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJumpUnreadData(), keys.allSatisfy({ data[$0] != nil }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadJumpUnreadData(), keys.allSatisfy({ data[$0] != nil }) {
            return true
        }
        return false
    }

    private func loadJumpUnreadData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}
