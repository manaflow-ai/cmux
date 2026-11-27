import Foundation
import Testing
@testable import CmuxNextDaemon

struct HistoryRequestPreflightTests {
    @Test(arguments: [[], ["terminal-command-history-v10"], ["terminal-command-history-v1"]])
    func legacyListAndDeleteRemainServedWithoutAnAdvertisement(capabilities: [String]) throws {
        let identity = DaemonIdentity(capabilities: capabilities, generation: "history-test")
        // This is the same preflight DaemonConnection.request runs before writing a frame.
        try ListTerminalCommandsRequest.requireServed(by: identity)
        try DeleteTerminalCommandsRequest.requireServed(by: identity)
    }

    @Test func legacyReadsAlsoPreserveUnknownIdentityPreflight() throws {
        try ListTerminalCommandsRequest.requireServed(by: nil)
        try DeleteTerminalCommandsRequest.requireServed(by: nil)
    }

    @Test(arguments: [[], ["terminal-command-history-v10"]])
    func settingsStillRequiresTheExactAdvertisement(capabilities: [String]) {
        let identity = DaemonIdentity(capabilities: capabilities, generation: "history-test")
        #expect(throws: DaemonError.missingCapabilities(["terminal-command-history-v1"])) {
            try SetTerminalCommandHistoryRequest.requireServed(by: identity)
        }
    }

    @Test func settingsRequiresKnownSupport() throws {
        #expect(throws: DaemonError.missingCapabilities(["terminal-command-history-v1"])) {
            try SetTerminalCommandHistoryRequest.requireServed(by: nil)
        }
        try SetTerminalCommandHistoryRequest.requireServed(by:
            DaemonIdentity(capabilities: ["terminal-command-history-v1"], generation: "history-test"))
    }
}
