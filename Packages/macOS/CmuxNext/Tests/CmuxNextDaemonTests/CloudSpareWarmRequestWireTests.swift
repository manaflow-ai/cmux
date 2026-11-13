import Foundation
import Testing
@testable import CmuxNextDaemon

/// `cloud-spare-warm` names a claimed or a ready spare to Rust (cmux-tui-core `SpareWarmParams`, which refuses unknown
/// fields); which one wins and what the ledger does with it is Rust's (`spare_warm/ready_tests.rs`, `daemon_tests.rs`).
struct CloudSpareWarmRequestWireTests {
    private func request(claimed: String? = nil, ready: String? = nil) -> CloudSpareWarmRequest {
        CloudSpareWarmRequest(platform: "https://platform.example", api: "https://api.example", accessToken: "stack-secret",
                              installToken: "install-secret", account: "user_a", claimed: claimed, ready: ready, team: nil,
                              loginTeams: [], dogfood: false, setting: nil, storedChoice: nil, consent: nil)
    }

    @Test func aReadySpareIsNamedToRust() throws {
        let fields = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request(ready: "vm_0123456789abcdefghij"), id: 1))
        #expect(fields["cmd"] == .string("cloud-spare-warm"))
        #expect(fields["ready"] == .string("vm_0123456789abcdefghij"))
        #expect(fields["claimed"] == nil || fields["claimed"] == .null)
        #expect(fields["account"] == .string("user_a") && fields["platform"] == .string("https://platform.example"))
    }

    @Test func aClaimedMachineIsNamedToRustAndAWarmNamesNone() throws {
        let claimed = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request(claimed: "vm_0123456789abcdefghij"), id: 1))
        #expect(claimed["claimed"] == .string("vm_0123456789abcdefghij"))
        #expect(claimed["ready"] == nil || claimed["ready"] == .null)
        let warm = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request(), id: 1))
        #expect(warm["claimed"] == nil || warm["claimed"] == .null)
        #expect(warm["ready"] == nil || warm["ready"] == .null)
    }

    @Test func theDescriptionPrintsNoToken() {
        let printed = String(describing: request(ready: "vm_0123456789abcdefghij"))
        #expect(!printed.contains("secret"))
        #expect(printed.contains("vm_0123456789abcdefghij"))
    }
}
