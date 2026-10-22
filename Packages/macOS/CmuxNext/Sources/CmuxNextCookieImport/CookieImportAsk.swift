import CmuxNextWakeups
public import Foundation
import Observation

/// One agent's cookie import ask while it is on screen: the request, the phase the card draws, and
/// the person's one answer. Whatever shows it (the inline card in Home, an agent chat's tool card,
/// or the window card) reads ``phase`` and calls ``answer(_:)``; the import service waits on
/// ``nextAnswer()``.
///
/// Safety rules it holds for every host:
/// - **One answer.** The first answer wins; later clicks, the deadline and a close do nothing.
/// - **Never automatic.** There is no "always allow"; each import asks again.
/// - **Armed after a beat.** Allow takes effect only ``armDelay`` after the card shows, so a click or
///   Return already on its way when the card appears under the pointer cannot answer it.
/// - **Deny by default.** No answer within ``limit`` is ``CookieImportAnswer/timedOut``.
@MainActor
@Observable
public final class CookieImportAsk: Identifiable {
    /// How long the card waits for an answer before it denies.
    public static let defaultLimit: Duration = .seconds(180)
    /// How long after showing the Allow button starts to work.
    public static let defaultArmDelay: Duration = .milliseconds(800)

    /// A stable id for hosts (the tool card's id, accessibility ids).
    public nonisolated let id: String
    /// What the card shows.
    public let request: CookieImportRequest
    /// Where the ask is.
    public internal(set) var phase: CookieImportPhase = .asking
    /// Allow works (``armDelay`` passed since ``shown()``).
    public private(set) var isArmed = false
    /// The person closed a finished card; hosts take it down.
    public private(set) var isDismissed = false
    /// How long the card waits.
    public let limit: Duration
    /// The person pressed "Show what was imported" on a finished card.
    public var showsSites = false

    /// Reveals the requester's tab (nil when it has none: a Home Chief, a program outside cmux).
    @ObservationIgnored public var onShowRequester: (@MainActor () -> Void)?
    /// Removes what this import brought in (set by the service once cookies came in).
    @ObservationIgnored var onRemove: (@MainActor () -> Void)?
    /// Opens the cookie imports window.
    @ObservationIgnored public var onShowAll: (@MainActor () -> Void)?

    @ObservationIgnored private var finish: ((CookieImportAnswer) -> Void)?
    @ObservationIgnored private let deadline: DemandTimer
    @ObservationIgnored private let arming: DemandTimer
    @ObservationIgnored private let armDelay: Duration
    @ObservationIgnored private var wasShown = false

    /// - Parameters:
    ///   - request: What the card shows.
    ///   - limit: How long to wait for an answer (default three minutes).
    ///   - armDelay: How long after ``shown()`` Allow starts to work.
    ///   - clock: Drives both delays (tests pass a manual clock).
    public init(request: CookieImportRequest, limit: Duration = CookieImportAsk.defaultLimit,
                armDelay: Duration = CookieImportAsk.defaultArmDelay, clock: any Clock<Duration> = ContinuousClock()) {
        id = "cookie-import-" + UUID().uuidString.lowercased()
        self.request = request
        self.limit = limit
        self.armDelay = armDelay
        deadline = DemandTimer(owner: "CookieImportAsk.deadline", clock: clock)
        arming = DemandTimer(owner: "CookieImportAsk.arming", clock: clock)
    }

    /// The host put the card on screen: the deadline and the arming delay start (once).
    public func shown() {
        guard !wasShown, phase.isAsking else { return }
        wasShown = true
        deadline.schedule(after: limit) { @MainActor [weak self] in self?.answer(.timedOut) }
        // Bounded, cancellable delay that is itself the behavior (the card's arming beat).
        if armDelay <= .zero { isArmed = true } else { arming.schedule(after: armDelay) { @MainActor [weak self] in self?.isArmed = true } }
    }

    /// The person's answer; an Allow before the card is armed is ignored. Only the first counts.
    public func answer(_ answer: CookieImportAnswer) {
        guard phase.isAsking, answered == nil else { return }
        if answer == .allow, !isArmed { return }
        answered = answer
        deadline.cancel()
        arming.cancel()
        if answer == .allow { phase = .reading }
        finish?(answer)
        finish = nil
    }

    /// The answer given, nil while the card still asks.
    public private(set) var answered: CookieImportAnswer?

    /// Waits for the person's answer.
    func nextAnswer() async -> CookieImportAnswer {
        if let answered { return answered }
        return await withCheckedContinuation { continuation in
            finish = { continuation.resume(returning: $0) }
        }
    }

    /// Removes what the import brought in (a finished card's Remove).
    public func remove() {
        guard case .imported = phase else { return }
        onRemove?()
    }

    /// The person closed the card. While it still asks, closing is Deny.
    public func dismiss() {
        if phase.isAsking {
            // Closing never needs the arming beat: it can only deny.
            answer(.deny)
        }
        isDismissed = true
    }

    /// Ends the ask with `text` (denied, timed out, failed); the card says it until dismissed.
    func end(_ text: String) {
        deadline.cancel()
        arming.cancel()
        phase = .ended(text)
    }
}
