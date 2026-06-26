/// High-level Mac power control used by the mobile host RPC so the phone can
/// sleep the Mac, disable keep-awake (caffeinate), and read whether the Mac is
/// being kept awake.
///
/// Stateless and `Sendable`: every system effect goes through an injected
/// ``MacPowerCommandRunning``, so the behavior is unit-testable with a fake
/// runner and never blocks the caller's actor.
public struct MacPowerController: Sendable {
    private let runner: any MacPowerCommandRunning

    public init(runner: any MacPowerCommandRunning = SystemMacPowerCommandRunner()) {
        self.runner = runner
    }

    /// Read the current keep-awake status from `pmset -g assertions`. Returns
    /// ``MacKeepAwakeStatus/idle`` if pmset cannot be run.
    public func keepAwakeStatus() async -> MacKeepAwakeStatus {
        guard let output = await runner.capture("/usr/bin/pmset", ["-g", "assertions"]) else {
            return .idle
        }
        return MacKeepAwakeStatus.parse(pmsetAssertions: output)
    }

    /// Put the whole Mac to sleep now.
    ///
    /// Uses AppleScript via `osascript` (`tell application "System Events" to
    /// sleep`) — the supported way to sleep without root. cmux ships the
    /// `com.apple.security.automation.apple-events` entitlement and an
    /// `NSAppleEventsUsageDescription`, so this works once the user has granted
    /// cmux Automation access to System Events. Returns whether the command
    /// exited cleanly (false when automation has not been granted yet).
    @discardableResult
    public func sleepSystem() async -> Bool {
        await runner.run(
            "/usr/bin/osascript",
            ["-e", "tell application \"System Events\" to sleep"]
        )
    }

    /// Disable active keep-awake by terminating every `caffeinate` process, then
    /// re-read the status so the caller can report whatever is still holding the
    /// Mac awake (e.g. a GUI app like Amphetamine that cannot be killed safely).
    public func disableKeepAwake() async -> MacKeepAwakeDisableOutcome {
        // `pkill -x caffeinate` exits 0 when it signaled at least one process,
        // 1 when none matched — the success bool is exactly "did we stop a
        // caffeinate".
        let terminated = await runner.run("/usr/bin/pkill", ["-x", "caffeinate"])
        let status = await keepAwakeStatus()
        return MacKeepAwakeDisableOutcome(terminatedCaffeinate: terminated, status: status)
    }
}
