public import Foundation

/// A check after an update failed: what the notice card offers and what the report files (Leo
/// 2026-11-21: "we ought to have good recovery and bisecting either automatically or agents being
/// able to just say "actually let's go back to this other version :)"").
nonisolated public struct UpdateHealthFailure: Equatable, Sendable {
    public var previousBuild: String
    public var previousCommit: String?
    public var build: String
    public var commit: String?
    /// The checks that failed, each with its reason.
    public var checks: [UpdateHealthCheck.Check]
    /// Whether a kept copy of ``previousBuild`` is there to go back to.
    public var canGoBack: Bool

    /// "chat: chat.handshake, relay: relay.refused".
    public var summary: String { checks.map { "\($0.name): \($0.reason)" }.joined(separator: ", ") }

    /// How a failure is filed: a non-fatal report's message, type, fingerprint, tags and extra
    /// (the crash reporter's `captureNonFatal`, which the App passes in).
    public typealias File = (_ message: String, _ type: String, _ fingerprint: [String], _ tags: [String: String], _ extra: [String: String]) -> Void

    /// Files this failure: both builds and both commits as tags, each check's reason and detail as extra.
    func file(with file: File) {
        file("update health check failed: \(summary)", "UpdateHealthCheckFailed",
             ["update-health-check"] + checks.map(\.reason).sorted(),
             ["previous_build": previousBuild, "build": build,
              "previous_commit": previousCommit ?? "unknown", "commit": commit ?? "unknown"],
             Dictionary(checks.map { ("check.\($0.name)", "\($0.reason): \($0.detail)") }, uniquingKeysWith: { $1 }))
    }
}

/// The check after a relaunch into a new build: once, after the launch settles, the running
/// bundle's `cmux app health` (``UpdateHealthCheck``) checks chat, the model picker, the relay and
/// a terminal. A failure is filed (``attachHealthCheck(socket:file:)``) and, with a kept copy of the build that
/// ran before, the notice card offers Go Back (``UpdateCard/healthFailed(previousBuild:reason:)``).
/// Automatic rollback on this verdict is a separate change. Never on a build the person picked
/// (a rollback or Install this version): going back from it is their call, and it stops a loop.
extension UpdaterService {
    /// The build the last launch ran (the check runs when this launch's differs).
    static let healthCheckedBuildKey = "cmux.next.updates.healthCheck.lastBuild"
    /// How long after ``start()`` the check waits: the restored chats and terminals settle first.
    static let healthCheckDelay: Duration = .seconds(45)

    /// The App's part: this app's control socket, and the crash reporter that files a failure.
    public func attachHealthCheck(socket: @escaping () -> String?, file: @escaping UpdateHealthFailure.File) {
        healthCheckSocket = socket
        healthCheckFile = file
    }

    /// Called once from ``start()``: records this launch's build and, after an update, schedules the check.
    func scheduleHealthCheckAfterUpdate() {
        let previous = defaults.string(forKey: Self.healthCheckedBuildKey)
        defaults.set(identity.build, forKey: Self.healthCheckedBuildKey)
        guard let previous, previous != identity.build, identity.track != .development else { return }
        log.append("health check: \(previous) -> \(identity.build), checking in \(Self.healthCheckDelay)")
        Task { [weak self] in
            // wakeup-allow: one 45 s wait, once per launch, only after a relaunch into a new build
            do { try await Task.sleep(for: Self.healthCheckDelay) } catch { return }
            await self?.runHealthCheck(previous: previous)
        }
    }

    func runHealthCheck(previous: String) async {
        guard let socket = healthCheckSocket?() else {
            log.append("health check: skipped (no control socket)")
            return
        }
        guard let report = await UpdateHealthCheck(bundle: Bundle.main.bundleURL).run(socket: socket, since: launchedAt) else {
            log.append("health check: no report (no app answered, or the check timed out)")
            return
        }
        guard !report.ok else {
            log.append("health check: passed (\(report.checks.map(\.name).joined(separator: ", ")))")
            return
        }
        let kept = await Task.detached(priority: .utility) { [keptVersions] in
            keptVersions.list().first { $0.build == previous }.map { ($0, UpdateHealthCheck.commit(of: $0.bundle)) }
        }.value
        let failure = UpdateHealthFailure(previousBuild: previous, previousCommit: kept?.1, build: identity.build,
                                          commit: report.commit, checks: report.failed, canGoBack: kept != nil)
        log.append("health check: failed (\(failure.summary)); previous \(previous)\(kept == nil ? " is not kept" : " is kept")")
        if let healthCheckFile { failure.file(with: healthCheckFile) }
        guard failure.canGoBack, !runsPickedBuild else { return }
        healthFailure = failure
        followCardExpiry()
    }

    /// Go Back on the failed check's card: restarts into the kept
    /// build through the one drop-back path (``UpdateDropBack``), which refuses a kept build that
    /// cannot read the stores; a refusal stays on the card.
    public func goBackAfterHealthFailure() async {
        guard let failure = healthFailure else { return }
        log.append("health check: going back to \(failure.previousBuild)")
        if let refusal = await UpdateDropBack(self).failure(to: failure.previousBuild, stateDirectories: pulledWatch.stateDirectories()) {
            log.append("health check: go back refused: \(refusal)")
        }
    }

    /// The failed check's card, unless a check the person asked for shows its own.
    var healthCard: UpdateCard? {
        guard let healthFailure, !flow.userAsked else { return nil }
        return .healthFailed(previousBuild: healthFailure.previousBuild, reason: healthFailure.summary)
    }
}

nonisolated extension UpdaterStrings {
    static var healthFailedTitle: String { text("updater.health.title", "This Update Failed a Check") }
    static func healthFailedDetail(_ reason: String, _ build: String) -> String {
        format("updater.health.detail", "%1$@. Go back to %2$@, kept on this Mac; settings and sessions stay.", reason, build)
    }
    static var goBack: String { text("updater.health.goBack", "Go Back") }
}
