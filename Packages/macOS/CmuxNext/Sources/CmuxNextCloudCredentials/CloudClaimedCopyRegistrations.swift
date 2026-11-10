import CmuxNextCompat
import CmuxNextDaemon
public import Foundation

/// The claimed machines whose login copy (``CloudSpareWarm/start(claimed:)``) Rust has not registered yet. A start onto
/// such a machine waits here before it asks Rust's `wait-copy`, so it finds the claim's copy in flight and waits on it
/// instead of reading "no login" and installing a second copy beside it. The copy itself never holds anyone: only Rust's
/// answer to the claim (`warm-spare` with `claimed`, registered or deduplicated per machine) is awaited. It also keeps
/// the one task that tells the daemon the person's consent, which every copy in flight reads again.
@MainActor public final class CloudClaimedCopyRegistrations {
    private var pending: [String: [UUID: Task<Void, Never>]] = [:]
    /// The consent's follower (``followConsent(on:_:)``) and the daemon connection it sends on.
    private var consentFollower: (connection: DaemonConnection, task: Task<Void, Never>)?

    public init() {}

    /// Runs `register` (Rust's answer to the claim of `machine`) and keeps it pending until it answers.
    func register<Answer: Sendable>(_ machine: String, _ register: @escaping @MainActor @Sendable () async -> Answer) -> Task<Answer, Never> {
        let id = UUID()
        // task-owner: the returned task; it ends with the claim's one CLI call, whose own timeout bounds it.
        let answer = Task { @MainActor in await register() }
        // task-owner: `pending`, cleared by its own end below; bounded by `answer`.
        pending[machine, default: [:]][id] = Task { @MainActor [weak self] in
            _ = await answer.value
            self?.pending[machine]?[id] = nil
            if self?.pending[machine]?.isEmpty == true { self?.pending[machine] = nil }
        }
        return answer
    }

    /// Sends `consent` on `connection` at once and on every change (`cloud-spare-warm-consent`), so a login copy in flight
    /// reads it right before its write and a change ends it (cmux-tui-core `server/cloud_spare_warm.rs`). One follower: a
    /// warm on another connection (a restarted daemon) moves it there.
    func followConsent(on connection: DaemonConnection, _ consent: @escaping @MainActor @Sendable () -> Bool?) {
        guard consentFollower?.connection !== connection else { return }
        consentFollower?.task.cancel()
        // task-owner: `consentFollower`, cancelled when a warm comes on another connection; each send is bounded by its timeout.
        consentFollower = (connection, Task { @MainActor in
            for await value in ObservationStream(consent) {
                _ = try? await connection.request(CloudSpareWarmConsentRequest(consent: value), timeout: .seconds(5))
            }
        })
    }

    /// Returns once every registration of `machine` pending now has answered; at once when there is none.
    public func registered(_ machine: String) async {
        while let next = pending[machine]?.values.first { await next.value }
    }

    /// How many machines have a registration pending (tests).
    var pendingCount: Int { pending.count }
}
