import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
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
    /// The number of the last consent read (``consentGeneration()``).
    private var consentReads: UInt64 = 0

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

    /// Sends the consent on `connection` at once, on every change and on every reconnect (`cloud-spare-warm-consent`), so
    /// a login copy in flight reads it right before its write and a change ends it (cmux-tui-core `server/cloud_spare_warm.rs`).
    /// A change while the link is down is sent when it comes back. One follower: a warm on another connection moves it there.
    func followConsent(on connection: DaemonConnection, _ consent: @escaping @MainActor @Sendable () -> CloudLoginCopyConsentNow) {
        guard consentFollower?.connection !== connection else { return }
        consentFollower?.task.cancel()
        // task-owner: `consentFollower`, cancelled when a warm comes on another connection; each send is bounded by its timeout.
        consentFollower = (connection, Task { @MainActor [weak self] in
            var push = CloudLoginCopyConsentPush()
            for await _ in ObservationStream(consent) {
                // A re-send only repairs a lost request: full jitter, so many apps that failed together never re-send together.
                var backoff = Backoff.fullJitter(initial: CloudLoginCopyConsentPush.retryDelays[0], maximum: CloudLoginCopyConsentPush.retryDelays[2])
                await push.send(consent, numbered: { self?.consentGeneration() }, { value, generation in
                    let request = CloudSpareWarmConsentRequest(consent: value, generation: generation)
                    return (try? await connection.request(request, timeout: .seconds(5))) != nil
                }, pause: { _ in
                    // concurrency-allow: Backoff.wait is an async sleep after a failed send, not a blocking wait.
                    (try? await backoff.wait(owner: "cloud-spare-warm.consent-resend")) != nil
                })
            }
        })
    }

    /// The next number for a consent read, taken on the main actor when the consent is read: every send carries one, and
    /// the daemon drops a send whose read is older than one it already took (a warm that read yes, then awaited its
    /// tokens while the person turned copying off and the follower sent no).
    func consentGeneration() -> UInt64 {
        consentReads += 1
        return consentReads
    }

    /// Returns once every registration of `machine` pending now has answered; at once when there is none.
    public func registered(_ machine: String) async {
        while let next = pending[machine]?.values.first { await next.value }
    }

    /// How many machines have a registration pending (tests).
    var pendingCount: Int { pending.count }
}

/// The consent follower's input: the person's consent now (nil: never asked or managed) and whether the daemon link is up.
public struct CloudLoginCopyConsentNow: Sendable, Equatable {
    public var live: Bool, consent: Bool?
    public init(live: Bool, consent: Bool?) { (self.live, self.consent) = (live, consent) }
}

/// What the follower sends for each state it observes: the consent whenever the link is up and the daemon was not told it
/// on this link yet. A drop forgets what was sent, so a reconnect (and a change made while down) sends it again; a failed
/// send is sent again with the next state.
struct CloudLoginCopyConsentPush {
    /// The consent the daemon holds on the current link; nil: none sent on it yet.
    private var sent: Bool??

    /// The consent to send now, or nil to send nothing.
    mutating func next(_ now: CloudLoginCopyConsentNow) -> Bool?? {
        guard now.live else { sent = nil; return nil }
        guard sent != .some(now.consent) else { return nil }
        sent = .some(now.consent)
        return .some(now.consent)
    }

    mutating func failed() { sent = nil }

    /// The cap of each wait before a failed send is sent again, each retry once (the follower draws each under
    /// ``Backoff/fullJitter(initial:maximum:random:)``): a send that fails while the link stays up
    /// and the consent stays the same has no next state to ride on, and the daemon would keep the old consent for a
    /// copy in flight (an opt-out it never heard). After the last, the next change or reconnect sends it.
    static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

    /// Sends what ``next(_:)`` says for the consent now, and again after each of ``retryDelays`` while the send fails.
    /// Each try reads the consent afresh and is `numbered` in the same main-actor step (a warm can read in between, and
    /// its read must not outnumber a newer one); a try stops once the link is down, which a reconnect resends.
    /// `pause` answers false when the follower is cancelled.
    @MainActor mutating func send(
        _ consent: () -> CloudLoginCopyConsentNow, numbered: () -> UInt64?,
        _ request: (Bool?, UInt64) async -> Bool, pause: (Duration) async -> Bool
    ) async {
        for delay in [nil] + Self.retryDelays.map(Optional.some) {
            if let delay, !(await pause(delay)) { return }
            guard let value = next(consent()), let generation = numbered() else { return }
            if await request(value, generation) { return }
            failed()
        }
    }
}
