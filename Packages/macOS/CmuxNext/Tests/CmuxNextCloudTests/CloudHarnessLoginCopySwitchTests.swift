@testable import CmuxNextCloud
import Foundation
import Testing

/// The Release login copy's remote off switch (Leo, 2026-11-02: "A remote off switch, so if Anthropic
/// objects we turn it off for everyone within minutes"). It fails closed.
@Suite struct CloudHarnessLoginCopySwitchTests {
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
