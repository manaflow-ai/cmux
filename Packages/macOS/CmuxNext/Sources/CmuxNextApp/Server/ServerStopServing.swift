import CmuxNextCompat
import CmuxNextServerHelper
import CmuxNextWakeups
import Foundation
import ServiceManagement

/// One launchd job the app registers with `SMAppService`, as a seam. `status` and `register` wait for
/// backgroundtaskmanagementd's reply, so the app runs them through the blocking seams on the system lane,
/// never on the main thread (Chrome's UI-thread rule, base/threading/scoped_blocking_call.h).
struct ServerServiceRegistration {
    var status: @MainActor () async -> SMAppService.Status
    var register: @MainActor () async throws -> Void
    var unregister: @MainActor () async throws -> Void
    var openLoginItems: @MainActor () -> Void = { SMAppService.openSystemSettingsLoginItems() }

    /// The cmux server LaunchAgent (``ServerLaunchAgent``).
    static func agent(work: BackgroundWork) -> ServerServiceRegistration {
        let name = ServerLaunchAgent.plistName
        return app(work: work) { .agent(plistName: name) }
    }

    /// The privileged helper LaunchDaemon (``ServerHelperClient``).
    static func helper(work: BackgroundWork) -> ServerServiceRegistration {
        let name = ServerHelperConstants().plistName
        return app(work: work) { .daemon(plistName: name) }
    }

    /// A status the lane could not read (the caller was cancelled) is `.notFound`.
    private static func app(work: BackgroundWork, _ service: @escaping @Sendable () -> SMAppService) -> ServerServiceRegistration {
        ServerServiceRegistration(
            status: { (try? await work.run(.userBlocking, mayBlock: .system) { blockingSMAppServiceStatus(service()) }) ?? .notFound },
            register: { try await work.run(.userBlocking, mayBlock: .system) { try blockingSMAppServiceRegister(service()) } },
            unregister: { try await service().unregister() })
    }

    /// Registers the job. Idempotent: an enabled job stays enabled. It may open System Settings, so
    /// call it from an explicit user action only.
    func enable<Failure: Error>(requiresApproval: Failure, failed: (String) -> Failure) async throws(Failure) {
        switch await status() {
        case .enabled:
            return
        case .requiresApproval:
            break
        default:
            do {
                try await register()
            } catch {
                throw failed(String(describing: error))
            }
            guard await status() == .requiresApproval else { return }
        }
        openLoginItems()
        throw requiresApproval
    }
}

/// `server.stopServing` (plans/cmux-next/server.md 4.4 and 9.4): puts back
/// every power setting a fix changed (the helper's revert restores the value
/// it recorded), then unregisters the server LaunchAgent and the privileged
/// helper. Idempotent: a job that is not registered is skipped, and a fix
/// with nothing recorded is not an error. An enabled helper reverts every
/// allowlisted fix; otherwise the app's `ServerFixLedger` decides, and an
/// empty ledger never needs the helper or its approval. When a revert fails,
/// or recorded fixes remain and the helper awaits approval in Login Items,
/// the helper stays registered so the user can stop serving again and get
/// the settings back; the agent is still removed. A running Fix finishes its
/// current step first (`ServerFixGate`), so no apply lands after its revert.
struct ServerStopServing {
    enum Failure: Error, Equatable {
        case revert(String)
        case unregister(String)
        /// Fixes are recorded but no helper is registered to restore them.
        case notRestored

        var message: String {
            switch self {
            case .notRestored:
                RefusalStrings.text("refusal.server.notRestored",
                                    "Some power settings changed by Fix were not restored. Run Fix and Stop Serving again.")
            case let .revert(reason):
                RefusalStrings.format("refusal.server.revertFailed", "Could not restore your power settings: %@", reason)
            case let .unregister(reason):
                RefusalStrings.format("refusal.server.stopFailed", "Could not stop serving: %@", reason)
            }
        }
    }

    /// Nil when this build does not carry the job.
    var agent: ServerServiceRegistration?
    var helper: ServerServiceRegistration?
    var revert: @MainActor (ServerFix) async throws(ServerHelperClient.Failure) -> Void
    var gate: ServerFixGate = .shared
    /// The fixes this app had the helper apply.
    let ledger: ServerFixLedger

    static func app(work: BackgroundWork) -> ServerStopServing {
        let helper = ServerServiceRegistration.helper(work: work)
        return ServerStopServing(
            agent: ServerLaunchAgent.isBundled ? .agent(work: work) : nil,
            helper: ServerHelperClient.isBundled ? helper : nil,
            revert: { (fix: ServerFix) async throws(ServerHelperClient.Failure) in
                try await ServerHelperClient.run(fix, revert: true, helper: helper)
            }, ledger: .standard)
    }

    /// Holds the gate until the helper is gone, so a Fix queued behind Stop
    /// Serving cannot apply after the reverts.
    func run() async throws(Failure) {
        await gate.acquire()
        defer { gate.release() }
        let revertFailure = await revertRecorded()
        if let agent { try await unregister(agent) }
        if let revertFailure { throw revertFailure }
        if let helper { try await unregister(helper) }
    }

    /// An enabled helper reverts every allowlisted fix, whatever the ledger
    /// says (a lost ledger must not leave a setting changed). Otherwise the
    /// ledger decides: recorded fixes and a helper awaiting approval keep the
    /// helper; nothing recorded needs no helper; recorded fixes with no
    /// helper registered keep their entries and say so.
    /// Nil when nothing is left to restore, else the failure.
    private func revertRecorded() async -> Failure? {
        let recorded = await ledger.load()
        switch await helper?.status() {
        case .enabled:
            break
        case .requiresApproval:
            return recorded.toRevert.isEmpty ? nil : .revert(ServerHealthFixer.reject(for: .requiresApproval))
        default:
            // No helper is registered: none can revert; the ledger keeps its entries.
            return recorded.toRevert.isEmpty ? nil : .notRestored
        }
        var failure: String?
        for fix in ServerFix.allCases {
            do throws(ServerHelperClient.Failure) {
                try await revert(fix)
            } catch {
                guard case let .refused(reason) = error, reason == ServerHelperService.nothingToRevert else {
                    failure = failure ?? ServerHealthFixer.reject(for: error)
                    continue
                }
            }
            // Only a revert that succeeded, or found nothing to revert, clears its entry.
            try? await ledger.clear(fix)
        }
        // An unreadable ledger is emptied after a clean full revert; a foreign
        // one keeps the ids this build cannot revert.
        if failure == nil, recorded == .unknown { try? await ledger.reset() }
        return failure.map(Failure.revert)
    }

    private func unregister(_ job: ServerServiceRegistration) async throws(Failure) {
        guard await job.status() != .notRegistered else { return }
        do {
            try await job.unregister()
        } catch {
            throw .unregister(String(describing: error))
        }
    }
}
