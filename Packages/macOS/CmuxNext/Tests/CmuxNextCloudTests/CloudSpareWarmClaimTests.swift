@testable import CmuxNextCloud
import Foundation
import Testing

/// The login copy a reserve's or a claim's machine starts (cmux-platform#1084, item (a)): off unless
/// `cmux.cloud.copyLoginOnClaim` is on, and it names that exact machine to Rust's `warm-spare`, which keys
/// the copy in flight on it.
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

    @Test func aClaimedMachineIsNamedToRust() {
        let platform = URL(string: "https://platform.example")!
        let claimed = CloudMoveCLI.spareWarmRequest(platform: platform, account: "user_a", end: nil, claimed: "vm_0123456789abcdefghij")
        #expect(claimed["claimed"] as? String == "vm_0123456789abcdefghij")
        #expect(claimed["account"] as? String == "user_a" && claimed["platform"] as? String == platform.absoluteString)
        // A warm names no machine; an end names the machine it ends and claims nothing.
        #expect(CloudMoveCLI.spareWarmRequest(platform: platform, account: "user_a", end: nil, claimed: nil)["claimed"] == nil)
        let finished = CloudMoveCLI.spareWarmRequest(platform: platform, account: "user_a", end: .finished("vm_0123456789abcdefghij"), claimed: nil)
        #expect(finished["finished"] as? String == "vm_0123456789abcdefghij" && finished["claimed"] == nil)
        // An installed copy is named as such: Rust keeps it as the start's login receipt.
        let installed = CloudMoveCLI.spareWarmRequest(platform: platform, account: "user_a", end: .installed("vm_0123456789abcdefghij"), claimed: nil)
        #expect(installed["installed"] as? String == "vm_0123456789abcdefghij" && installed["finished"] == nil && installed["claimed"] == nil)
    }

    @Test func aReservationsMachineIsTheOneItAnswered() {
        #expect(CloudMoveCLI.reservedMachine(["ok": true, "leaseId": "lease-1", "machine": "vm_0123456789abcdefghij"]) == "vm_0123456789abcdefghij")
        #expect(CloudMoveCLI.reservedMachine(["ok": false, "machine": "vm_0123456789abcdefghij"]) == nil)
        #expect(CloudMoveCLI.reservedMachine(["ok": true]) == nil)
        #expect(CloudMoveCLI.reservedMachine(["ok": true, "machine": ""]) == nil)
    }
}
