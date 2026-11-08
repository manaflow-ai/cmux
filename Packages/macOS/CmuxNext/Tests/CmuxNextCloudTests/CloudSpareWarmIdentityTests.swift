@testable import CmuxNextCloud
import Testing

/// Leo, Cloud V0 item 1: "harness login attached in advance". The warm's pre-copy is bound to the one account and
/// backend team that asked for it (Rust's `copy`, cmux-tui start_chat_cli/spare_warm.rs; CloudStartChat+WarmSpare).
@Suite struct CloudSpareWarmIdentityTests {
    private let warm = CloudMoveCLI.SpareWarm(machineID: "vm_0123456789abcdefghij", account: "user_a", team: "team_0123456789abcdef0123")

    @Test func anAccountOrTeamSwitchMidWarmCopiesNothing() {
        #expect(warm.copyAllowed(account: "user_a", team: "team_0123456789abcdef0123"))
        #expect(!warm.copyAllowed(account: "user_b", team: "team_0123456789abcdef0123"))
        #expect(!warm.copyAllowed(account: "user_a", team: "team_ffffffffffffffffffff"))
        #expect(!warm.copyAllowed(account: "user_a", team: nil))
        #expect(!warm.copyAllowed(account: nil, team: "team_0123456789abcdef0123"))
    }
}
