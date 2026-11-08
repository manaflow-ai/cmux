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

/// The warm's sequencing (``CloudSpareWarms``): an intent never waits on a warm, and only a start that would race the
/// warm's copy on its machine (Rust's `warmCopyConflict`, true for Claude only) waits on that copy.
@MainActor @Suite struct CloudSpareWarmSequencingTests {
    @MainActor private final class Count { var value = 0 }

    /// A gate a warm or copy waits on until the test opens it.
    private func gate() -> (wait: @MainActor () async -> Void, open: () -> Void) {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        return ({ for await _ in stream {} }, { continuation.finish() })
    }

    @Test func aSecondActivationWhileAWarmIsPendingIsHandledAtOnce() async {
        let warms = CloudSpareWarms(), (wait, open) = gate()
        let runs = Count()
        // `start` is synchronous: the activation that asks returns while the warm is still pending.
        let first = warms.start("user_a|team_a") { runs.value += 1; await wait() }
        let second = warms.start("user_a|team_a") { runs.value += 1 }
        #expect(first == second && warms.isWarming("user_a|team_a"))
        // Another identity's warm starts its own instead of waiting on this one.
        let other = warms.start("user_b|team_a") {}
        #expect(other != first)
        await other.value
        open()
        await first.value
        #expect(runs.value == 1 && !warms.isWarming("user_a|team_a"))
    }

    @Test func aCodexStartDoesNotWaitOnAPendingClaudeCopyAndAClaudeStartOntoTheWarmedMachineDoes() async {
        let warms = CloudSpareWarms(), (wait, open) = gate()
        let copy = warms.copy(onto: "vm_a") { await wait(); return true }
        // Codex (no conflict) and any start on another machine return while the copy is still pending.
        await warms.waitForCopy(onto: "vm_a", conflicts: false)
        await warms.waitForCopy(onto: "vm_b", conflicts: true)
        #expect(warms.isCopying("vm_a"))
        // A Claude start onto the warmed machine waits until the copy ends.
        let claudeWaited = Count()
        let claude = Task { @MainActor in
            await warms.waitForCopy(onto: "vm_a", conflicts: true)
            claudeWaited.value = 1
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(claudeWaited.value == 0 && warms.isCopying("vm_a"))
        open()
        await claude.value
        #expect(claudeWaited.value == 1 && !warms.isCopying("vm_a"))
        #expect(await copy.value)
    }

    @Test func sendsPreparationNeverWaitsOnAWarm() async {
        // The reservation hook starts the warm and goes straight on to the reserve: a warm that never ends (a 70 s warm
        // and a 45 s guest check) adds nothing to Send's wait, so its gesture ticket's lifetime covers only the reserve.
        let warms = CloudSpareWarms(), (wait, open) = gate(), (copyWait, copyOpen) = gate()
        let warm = warms.start("user_a|team_a") { await wait() }
        // Reached with the warm still pending: the reserve goes out now.
        #expect(warms.isWarming("user_a|team_a"))
        // A start with no conflict (no copy, or Codex) does not wait on it either.
        let copy = warms.copy(onto: "vm_a") { await copyWait(); return false }
        await warms.waitForCopy(onto: "vm_a", conflicts: false)
        #expect(warms.isCopying("vm_a"))
        copyOpen()
        #expect(await copy.value == false)
        open()
        await warm.value
    }
}
