@testable import CmuxNextCloud
import Foundation
import Testing

/// The login copy a reserve's or a claim's machine starts (cmux-platform#1084, item (a)): on unless
/// `cmux.cloud.copyLoginOnClaim` is NO. Naming the machine to Rust and keying its copy is the daemon's
/// `cloud-spare-warm` (cmux-tui `spare_warm/daemon_tests.rs`).
@Suite struct CloudSpareWarmClaimTests {
    @Test func theCopyOnClaimIsOnByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "CloudSpareWarmClaimTests-\(UUID().uuidString)"))
        #expect(CloudMoveCLI.copiesLoginOnClaim(defaults))
        defaults.set(false, forKey: CloudMoveCLI.copyLoginOnClaimKey)
        #expect(!CloudMoveCLI.copiesLoginOnClaim(defaults))
        defaults.set(true, forKey: CloudMoveCLI.copyLoginOnClaimKey)
        #expect(CloudMoveCLI.copiesLoginOnClaim(defaults))
        #expect(CloudMoveCLI.copyLoginOnClaimKey == "cmux.cloud.copyLoginOnClaim")
    }

    @Test func aReservationsMachineIsTheOneItAnswered() {
        #expect(CloudMoveCLI.reservedMachine(["ok": true, "leaseId": "lease-1", "machine": "vm_0123456789abcdefghij"]) == "vm_0123456789abcdefghij")
        #expect(CloudMoveCLI.reservedMachine(["ok": false, "machine": "vm_0123456789abcdefghij"]) == nil)
        #expect(CloudMoveCLI.reservedMachine(["ok": true]) == nil)
        #expect(CloudMoveCLI.reservedMachine(["ok": true, "machine": ""]) == nil)
    }
}
