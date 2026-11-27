@testable import CmuxNextCloud
import Foundation
import Testing

/// The Release login copy's remote off switch (Leo, 2026-11-02: "A remote off switch, so if Anthropic
/// objects we turn it off for everyone within minutes"). It fails closed.
@Suite struct CloudHarnessLoginCopySwitchTests {
    @Test func theRoutesAnswerDecodesPlainOrWrapped() throws {
        let plain = try CloudOwnerAPIClient.decodeHarnessLoginCopy(Data(#"{"enabled":true,"ttlSeconds":120}"#.utf8))
        #expect(plain == .init(enabled: true, ttlSeconds: 120))
        let wrapped = try CloudOwnerAPIClient.decodeHarnessLoginCopy(Data(#"{"ok":true,"value":{"enabled":false,"ttlSeconds":60}}"#.utf8))
        #expect(wrapped == .init(enabled: false, ttlSeconds: 60))
        // A ttl longer than five minutes is cut to five: the switch always takes effect within that.
        #expect(try CloudOwnerAPIClient.decodeHarnessLoginCopy(Data(#"{"enabled":true,"ttlSeconds":86400}"#.utf8)).ttlSeconds == 300)
        #expect(throws: (any Error).self) { try CloudOwnerAPIClient.decodeHarnessLoginCopy(Data(#"{"enabled":"yes"}"#.utf8)) }
    }

    @Test func neverReadOrStaleIsOff() {
        let remote = CloudHarnessLoginCopySwitch()
        #expect(remote.current == nil)
        remote.set(true)
        #expect(remote.current == true)
        remote.set(false)
        #expect(remote.current == false)
        remote.set(true, ttlSeconds: 300, age: .seconds(301))
        #expect(remote.current == nil)
        remote.set(nil)
        #expect(remote.current == nil)
    }
}
