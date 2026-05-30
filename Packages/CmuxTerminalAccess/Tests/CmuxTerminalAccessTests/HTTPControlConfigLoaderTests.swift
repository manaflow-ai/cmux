// SPDX-License-Identifier: MIT
//
// Task 1.20 / D14 / E7 — behavioral round-trip of the `httpControl`
// block in `cmux.json` through the real loader. Replaces any
// schema-text-grep tests (forbidden under the test quality policy).

import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct HTTPControlConfigLoaderTests {
    @Test func parseAcceptsHTTPControlBlockAndRoundTrips() throws {
        let json = """
        {
          "enabled": true,
          "transport": "uds",
          "tcpPort": 9999,
          "udsPath": "/tmp/cmux-test.sock",
          "allowRawInput": false,
          "auditLogPath": "/tmp/cmux-audit.log"
        }
        """
        let cfg = try HTTPControlConfigLoader.parse(Data(json.utf8))
        #expect(cfg.enabled == true)
        #expect(cfg.transport == .uds)
        #expect(cfg.tcpPort == 9999)
        #expect(cfg.udsPath == "/tmp/cmux-test.sock")
        #expect(cfg.allowRawInput == false)
        #expect(cfg.auditLogPath == "/tmp/cmux-audit.log")
    }

    @Test func parseRejectsBadTransportEnum() throws {
        let json = """
        { "transport": "bonkers" }
        """
        #expect(throws: DecodingError.self) {
            _ = try HTTPControlConfigLoader.parse(Data(json.utf8))
        }
    }

    @Test func parseAcceptsPartialBlock() throws {
        // Only the master switch is set; everything else falls back
        // to the runtime defaults when the lifecycle merges this in.
        let json = """
        { "enabled": true }
        """
        let cfg = try HTTPControlConfigLoader.parse(Data(json.utf8))
        #expect(cfg.enabled == true)
        #expect(cfg.transport == nil)
        #expect(cfg.tcpPort == nil)
        #expect(cfg.udsPath == nil)
        #expect(cfg.allowRawInput == nil)
        #expect(cfg.auditLogPath == nil)
    }

    @Test func parseAcceptsTCPTransport() throws {
        let json = """
        { "transport": "tcp" }
        """
        let cfg = try HTTPControlConfigLoader.parse(Data(json.utf8))
        #expect(cfg.transport == .tcp)
    }
}
