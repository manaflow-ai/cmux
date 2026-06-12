#if DEBUG
import Foundation
import Testing
import CmuxTerminalCore

@Suite struct TerminalChildExitProbeTests {
    @Test func loadReturnsEmptyPayloadForMissingFile() {
        #expect(TerminalChildExitProbe().load(at: "/tmp/cmux-termcore-missing-\(UUID().uuidString)") == [:])
    }

    @Test func loadRoundTripsJSONPayload() throws {
        let path = NSTemporaryDirectory() + "cmux-termcore-probe-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let payload = ["probeKeyDownCount": "2", "probeLastKey": "0024"]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: path))
        #expect(TerminalChildExitProbe().load(at: path) == payload)
    }

    @Test func writeIsInertWithoutEnvironmentOptIn() {
        // The test process does not set CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP,
        // so probePath() is nil and write must be a no-op.
        #expect(TerminalChildExitProbe().probePath() == nil)
        TerminalChildExitProbe().write(["probe": "1"], increments: ["count": 1])
    }
}

@Suite struct UnicodeScalarHexListTests {
    @Test func encodesScalarsAsUppercaseHexList() {
        #expect("a".unicodeScalarHexList == "0061")
        #expect("ab".unicodeScalarHexList == "0061,0062")
        #expect("".unicodeScalarHexList == "")
        #expect("\u{1F600}".unicodeScalarHexList == "1F600")
    }
}
#endif
