import Testing
@testable import CmuxNextBrowser

@Suite struct CEFMeasureMediaSwitchTests {
    @Test(arguments: [
        ("com.cmuxterm.app.nightly.side-meetbrowser-abcdef", true, true, true),
        ("com.cmuxterm.app.nightly.side-meetbrowser-abcdef", true, false, false),
        ("com.cmuxterm.app.nightly.side-meetbrowser-abcdef", false, true, false),
        ("com.cmuxterm.app.nightly.side-other-abcdef", true, true, false),
        ("com.cmuxterm.app.nightly", true, true, false),
    ])
    func fakeCaptureIsScopedToTheRequestedSideRun(bundle: String, mockKeychain: Bool, requested: Bool, expected: Bool) {
        let switches = CEFSwitches.current(
            forkAPIVersion: 0,
            bundleIdentifier: bundle,
            environment: mockKeychain ? ["CMUX_MOCK_KEYCHAIN": "1"] : [:],
            processArguments: requested ? ["cmux", "--cmux-measure-fake-media"] : ["cmux"]
        ).arguments
        #expect(switches.contains("use-fake-device-for-media-stream") == expected)
        #expect(switches.contains("use-fake-ui-for-media-stream") == expected)
    }
}
