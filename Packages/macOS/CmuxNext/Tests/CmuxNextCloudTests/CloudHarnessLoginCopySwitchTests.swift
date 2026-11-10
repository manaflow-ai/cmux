@testable import CmuxNextCloud
import Foundation
import Testing

/// The Release login copy's remote off switch (Leo, 2026-11-02: "A remote off switch, so if Anthropic
/// objects we turn it off for everyone within minutes"). It fails closed.
@Suite struct CloudHarnessLoginCopySwitchTests {
    /// The answer (read and clamped to five minutes by cmux-cloud-machine `harness_copy::read`) is the daemon's.
    @Test func theSwitchIsTheDaemonsOwnerRead() async throws {
        let fake = CloudDaemonFake { _, _ in CloudDaemonFake.read(#"{"enabled":true,"ttlSeconds":120}"#) }
        let owner = CloudOwnerAPIClient(baseURL: try #require(URL(string: "https://api.invalid")), accessToken: { "access" },
                                        teamID: { "team_1" }, daemon: fake.daemon)
        #expect(try await owner.harnessLoginCopy() == .init(enabled: true, ttlSeconds: 120))
        #expect(fake.sent.map(\.operation) == ["cloud.owner.harness_login_copy"])
        #expect(fake.sent.first?.params["auth"] as? String == "owner")
        #expect(fake.sent.first?.params["team"] as? String == "team_1")
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
