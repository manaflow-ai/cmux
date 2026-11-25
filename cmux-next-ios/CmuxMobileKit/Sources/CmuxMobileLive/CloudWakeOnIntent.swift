#if os(iOS)
import CmuxMobileChief
import CmuxMobileLinkFFI
import CmuxMobileModel
import Foundation
import os

/// Wake on intent on the phone (the Mac's `AgentPaneCloudWakeOnIntent`): the app became active
/// with a Cloud machine's chat in front, so a paused machine starts its restore before the first
/// key. This forwards the raw signal with the facts the phone holds, runs the resume or re-pause
/// the rules answer, and logs each hint wake's outcome. Every decision (which signal counts,
/// debounce, cap, the no-input bound) is Rust's: cmux-mobile-link-ffi `cloud_wake.rs`, the Mac's
/// own `wake_hint` rules with one ledger per process. The hidden setting is
/// ``DeveloperOptions/wakeOnIntent`` (default off).
@MainActor
public final class CloudWakeOnIntent {
    public static let shared = CloudWakeOnIntent()

    private let logger = Logger(subsystem: "dev.cmux.mobile", category: "cloud.wake-hint")
    private let account: @MainActor () -> AccountCloud?
    private var timers: [String: Task<Void, Never>] = [:]

    init(account: @escaping @MainActor () -> AccountCloud? = { ChiefSources.shared.account }) {
        self.account = account
    }

    /// One raw signal (`unlock`) for the machine whose chat is in front.
    public func hint(_ machine: CloudChatMachine, signal: String) async {
        let enabled = DeveloperOptions.wakeOnIntent
        let account = account()
        // The status is read fresh only with the setting on; off, the rules answer `disabled`.
        let status = enabled ? await readStatus(machine, account) : nil
        let answer = cloudWakeHint(hint: CloudWakeHint(
            v: cloudWakeVersion(), machine: machine.machineID, signal: signal, enabled: enabled,
            allowed: account != nil, loaded: status != nil, status: status
        ))
        guard answer.resume, let account else { return }
        let ok = await mutate(account, "cloud.machine.start", machine)
        logger.info("wake hint \(signal, privacy: .public) resumed \(machine.machineID, privacy: .public): \(ok)")
        if let after = cloudWakeResumed(machine: machine.machineID, ok: ok) { schedule(machine, after: after) }
    }

    /// The person sent a prompt in machine `id`'s chat: a hint wake it had is `used`.
    public func input(machine id: String) {
        guard let outcome = cloudWakeInput(machine: id) else { return }
        timers.removeValue(forKey: id)?.cancel()
        log(id, outcome)
    }

    private func schedule(_ machine: CloudChatMachine, after ms: UInt64) {
        timers[machine.machineID]?.cancel()
        timers[machine.machineID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard !Task.isCancelled else { return }
            await self?.check(machine)
        }
    }

    private func check(_ machine: CloudChatMachine) async {
        let id = machine.machineID
        let account = account()
        let status = await readStatus(machine, account)
        switch cloudWakeIdle(machine: id, status: status) {
        case let .wait(after):
            schedule(machine, after: after)
        case let .pause(outcome):
            timers[id] = nil
            log(id, outcome)
            if let account { _ = await mutate(account, "cloud.machine.pause", machine) }
        case .done:
            timers[id] = nil
        }
    }

    /// The machine's status now (`cloud.machine.get`, the machine's Cloud team); nil unread.
    private func readStatus(_ machine: CloudChatMachine, _ account: AccountCloud?) async -> String? {
        guard let account,
              let value = try? await account.read("cloud.machine.get", params: ["machine": machine.machineID], team: machine.teamID)
        else { return nil }
        return CloudMachine.list(value).first { $0.id == machine.machineID }?.status.rawValue
    }

    /// A script-originated start or pause; true when the service accepted it.
    private func mutate(_ account: AccountCloud, _ op: String, _ machine: CloudChatMachine) async -> Bool {
        let key = "wake-\(op)-\(machine.machineID)-\(UUID().uuidString.lowercased())"
        return (try? await account.mutate(op, params: ["machine": machine.machineID], key: key, team: machine.teamID,
                                          origin: "script")) != nil
    }

    /// The wake log line: `used` with the lead from resume to input, or `false` with the awake ms.
    private func log(_ id: String, _ outcome: CloudWakeOutcome) {
        logger.info("wake hint outcome machine=\(id, privacy: .public) tag=\(outcome.tag, privacy: .public) signal=\(outcome.signal, privacy: .public) ms=\(outcome.ms)")
    }
}
#endif
