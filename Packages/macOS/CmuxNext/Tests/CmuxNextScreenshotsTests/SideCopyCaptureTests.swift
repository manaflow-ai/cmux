import CmuxNextScreenshots
import Testing

/// A script's capture is raw only in a side copy, read from the app's own Info.plist (SideCopyCapture).
struct SideCopyCaptureTests {
    private let sideEnvironment: [String: Any] = ["CMUX_MOCK_KEYCHAIN": "1", "CMUX_NEXT_CONFIG_FILE": "/side/wrec/config/cmux-next.json"]

    @Test func aSideCopyWithItsOwnStateIsOne() {
        #expect(SideCopyCapture.isSideCopy(bundleID: "com.cmuxterm.app.nightly.side-wrec-b4671f", info: ["LSEnvironment": sideEnvironment]))
    }

    @Test func thePersonsAppsNeverAre() {
        // The person's NIGHTLY, stable and a tagged dev build, even with the side copy's environment keys.
        for id in ["com.cmuxterm.app.nightly", "com.cmuxterm.app", "com.cmuxterm.app.debug.showcase"] {
            #expect(!SideCopyCapture.isSideCopy(bundleID: id, info: ["LSEnvironment": sideEnvironment]), "\(id)")
        }
        #expect(!SideCopyCapture.isSideCopy(bundleID: nil, info: ["LSEnvironment": sideEnvironment]))
    }

    @Test func aSideNamedBundleWithoutItsOwnStateIsNot() {
        let id = "com.cmuxterm.app.nightly.side-wrec-b4671f"
        #expect(!SideCopyCapture.isSideCopy(bundleID: id, info: nil))
        #expect(!SideCopyCapture.isSideCopy(bundleID: id, info: ["LSEnvironment": ["CMUX_MOCK_KEYCHAIN": "1"]]))
        #expect(!SideCopyCapture.isSideCopy(bundleID: id, info: ["LSEnvironment": ["CMUX_NEXT_CONFIG_FILE": "/x"]]))
        #expect(!SideCopyCapture.isSideCopy(bundleID: id, info: ["LSEnvironment": ["CMUX_MOCK_KEYCHAIN": "0", "CMUX_NEXT_CONFIG_FILE": "/x"]]))
    }
}
