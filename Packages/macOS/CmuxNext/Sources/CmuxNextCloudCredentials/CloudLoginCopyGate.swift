/// The Release copy of the person's own Claude login to their own Cloud machine (Leo, 2026-11-02),
/// on his three conditions:
///
/// 1. "Consent first. It's on only after a clear one-time prompt: 'use my Claude login on my own
///    Cloud machines'." The answer is kept in cmux.json (`CloudLoginCopyConsentSetting`), which
///    only the person sets and Settings > Machines takes back.
/// 2. "Your token only: your own token, to your own machine. Never stored by us, never on team
///    machines, never shared." Only where the platform says the caller owns the machine and its
///    guest is an `owner` one (cmux-cloud-start-core; never a team guest in Release), written from
///    this Mac to the machine's disk over the machine routes, which keep and log none of it.
/// 3. "A remote off switch": `CloudHarnessLoginCopySwitch`, read before each copy. Off, the copy
///    is skipped and the machine's chat offers the one-click "Sign in to Claude".
///
/// DEV and NIGHTLY builds (`dogfood`) keep their dogfood gate: none of this is read there.
/// The App gives the gate its switch read, the person's kept answer and the consent dialog.
public struct CloudLoginCopyGate: Sendable {
    public var dogfood: Bool
    /// Reads the remote switch now: true only when it is on.
    public var readSwitch: @MainActor @Sendable () async -> Bool?
    /// The person's kept answer to the one-time consent; nil when never asked.
    public var consent: @MainActor @Sendable () -> Bool?
    /// Asks the one-time consent and keeps the answer; true for yes.
    public var ask: @MainActor @Sendable () async -> Bool

    public init(dogfood: Bool, readSwitch: @escaping @MainActor @Sendable () async -> Bool?, consent: @escaping @MainActor @Sendable () -> Bool?,
                ask: @escaping @MainActor @Sendable () async -> Bool) {
        self.dogfood = dogfood
        self.readSwitch = readSwitch
        self.consent = consent
        self.ask = ask
    }

    /// The transfer's last check before it writes the login (`CloudCredentialTransfer` `stillAllowed`):
    /// in Release, the switch read again and the person's consent still yes. DEV and NIGHTLY: always.
    public var stillAllowed: @Sendable () async -> Bool {
        guard !dogfood else { return { true } }
        return { [self] in await automaticAllowed() }
    }

    /// Whether a copy that asks nobody (an automatic recovery) may run now: the switch read fresh and
    /// the person's consent already yes.
    public func automaticAllowed() async -> Bool {
        guard await readSwitch() == true else { return false }
        return await consent() == true
    }

    /// A start's Release reads (``CloudHarnessLoginDecision``): the switch read fresh for every start, so
    /// turning it off holds the next machine, and the person's kept consent. DEV and NIGHTLY read neither.
    public func read(into decision: inout CloudHarnessLoginDecision) async {
        guard !dogfood else { return }
        decision.remoteSwitch = await readSwitch()
        decision.consent = await consent()
    }

    /// A start's `.askConsent` step: the one-time consent is the confirm, so yes copies with no second
    /// prompt. Records the answer in `decision`; true when the step is then `.install`.
    public func askConsent(_ decision: inout CloudHarnessLoginDecision) async -> Bool {
        guard await ask() else {
            decision.consent = await consent()
            decision.outcome = "declined"
            return false
        }
        decision.consent = true
        return decision.verdict.step == .install
    }

    /// Whether a turn card's recovery may copy a login now: a dogfood build always (its own gate). In
    /// Release, Claude only, with the switch read fresh and the person's consent, which an automatic
    /// recovery never asks.
    public func recoveryAllowed(claude: Bool, automatic: Bool) async -> Bool {
        guard !dogfood else { return true }
        guard claude else { return false }
        return await automatic ? automaticAllowed() : copyAllowed()
    }

    /// Whether a Release turn card may copy the login now (its recovery): the switch read fresh,
    /// then the person's consent, asked once. DEV and NIGHTLY builds answer true (their own gate).
    public func copyAllowed() async -> Bool {
        guard !dogfood else { return true }
        guard await readSwitch() == true else { return false }
        if let consent = await consent() { return consent }
        return await ask()
    }
}
