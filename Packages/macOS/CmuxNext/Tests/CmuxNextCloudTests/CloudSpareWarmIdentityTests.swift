@testable import CmuxNextCloud
import Testing

/// Leo, Cloud V0 item 1: "harness login attached in advance". The warm's pre-copy is bound to the one account and team
/// that asked for it, and goes only to a machine that person owns (CloudStartChat+WarmSpare).
@Suite struct CloudSpareWarmIdentityTests {
    private let warm = CloudMoveCLI.SpareWarm(machineID: "vm_0123456789abcdefghij", vmKind: "owner", account: "user_a", team: "team_a")

    @Test func anAccountOrTeamSwitchMidWarmCopiesNothing() {
        #expect(warm.copyAllowed(account: "user_a", team: "team_a"))
        #expect(!warm.copyAllowed(account: "user_b", team: "team_a"))
        #expect(!warm.copyAllowed(account: "user_a", team: "team_b"))
        #expect(!warm.copyAllowed(account: nil, team: "team_a"))
    }

    @Test func aTeamGuestMachineGetsNoPreCopy() {
        for kind in ["team", "guest", nil] as [String?] {
            var other = warm
            other.vmKind = kind
            #expect(!other.copyAllowed(account: "user_a", team: "team_a"))
        }
    }
}
