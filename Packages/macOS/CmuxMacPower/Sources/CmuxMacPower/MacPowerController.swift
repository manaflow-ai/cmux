import Foundation

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

    /// Read the current keep-awake status from `pmset -g assertions`.
    ///
    /// Returns `nil` if pmset cannot be run or times out, so callers can surface
    /// an unknown/error state instead of reporting a false idle status.
    public func keepAwakeStatus() async -> MacKeepAwakeStatus? {
        guard let output = await runner.capture("/usr/bin/pmset", ["-g", "assertions"]) else {
            return nil
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

    /// Disable active keep-awake by terminating caffeinate assertion holders,
    /// then re-read the status so the caller can report whatever is still
    /// holding the Mac awake (e.g. a GUI app like Amphetamine that cannot be
    /// killed safely).
    public func disableKeepAwake() async -> MacKeepAwakeDisableOutcome? {
        guard let statusBefore = await keepAwakeStatus() else { return nil }
        let caffeinatePIDs = statusBefore.holders
            .filter { isCaffeinateHolder($0) }
            .map(\.pid)
        guard !caffeinatePIDs.isEmpty else {
            return MacKeepAwakeDisableOutcome(terminatedCaffeinate: false, status: statusBefore)
        }

        var terminated = false
        for pid in caffeinatePIDs {
            guard await isCurrentlyCaffeinateProcess(pid: pid) else { continue }
            let didSignal = await runner.run("/bin/kill", [String(pid)])
            terminated = terminated || didSignal
        }
        guard let status = await keepAwakeStatus() else { return nil }
        return MacKeepAwakeDisableOutcome(terminatedCaffeinate: terminated, status: status)
    }

    private func isCaffeinateHolder(_ holder: MacPowerAssertionHolder) -> Bool {
        holder.processName.lowercased() == "caffeinate"
    }

    private func isCurrentlyCaffeinateProcess(pid: Int) async -> Bool {
        guard let command = await runner.capture("/bin/ps", ["-p", String(pid), "-o", "comm="]) else {
            return false
        }
        let firstLine = command.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return executable.lowercased() == "caffeinate"
    }
}
