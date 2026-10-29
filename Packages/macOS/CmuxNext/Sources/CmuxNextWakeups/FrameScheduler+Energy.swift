/// What a ``FrameScheduler`` holds of the Energy Saver policy it follows.
struct AmbientEnergyState {
    /// The source it follows; nil: it never caps or stops its ambient clients.
    var source: EnergyPolicySource?
    /// Tells the scheduler each change of ``source``.
    var link: MainActorEnergyLink?
    /// ``EnergyPolicy/ambientMaxFPS`` now; nil while uncapped.
    var cap: Int?
    /// ``EnergyPolicy/screensAsleep`` now.
    var screensAsleep = false
    /// Active ambient clients that wait while the displays sleep; they rejoin when the displays wake.
    var asleep: [ObjectIdentifier: FrameClient] = [:]
}

/// Carries each change of an ``EnergyPolicySource`` to a main-actor consumer (a ``FrameScheduler``),
/// until it is released: a seam adapter over the source's writer-thread observers.
final class MainActorEnergyLink {
    private let observation: EnergyPolicyObservation

    /// Calls `onChange` after each change of `source`.
    init(_ source: EnergyPolicySource, onChange: @escaping @MainActor @Sendable (EnergyPolicy) -> Void) {
        observation = source.observe { policy in
            // main-proof: observers run on the writer's thread, and the source's one writer is the @MainActor EnergyPolicyDriver
            MainActor.assumeIsolated { onChange(policy) }
        }
    }
}

/// Energy Saver on the frame schedulers.
///
/// Every scheduler follows the app's one policy (`MainWorkScheduler.energy`): ``FrameScheduler/app``
/// from ``FrameScheduler/install(displays:energy:)``, each window's from ``FrameScheduler/app``, the
/// ``MainWorkScheduler``'s from its owner. A client is ambient only when its owner asks for an ambient
/// rate (``FrameRate/isAmbient``); every existing client, `isAnimation: false` ones included, is
/// ``FrameRate/motion``. Under the saver an ambient client asks the link for at most
/// ``EnergyPolicy/ambientMaxFPS``, as Chrome's battery saver throttles frame sinks to 30 Hz
/// (`FrameSinkManagerImpl::UpdateThrottlingFrameIntervals`, components/viz/service/frame_sinks/frame_sink_manager_impl.cc),
/// and a motion client beside it keeps the link at the motion range. While the displays sleep the
/// ambient clients stop and wait, as viz stops BeginFrames to a display nobody sees
/// (`DisplayScheduler::SetVisible(false)`, components/viz/service/display/display_scheduler.cc).
extension FrameScheduler {
    /// The Energy Saver policy it follows (``follow(_:)``); nil: it never caps or stops its ambient
    /// clients (a test scheduler, or ``app`` before ``install(displays:energy:)``).
    public var energy: EnergyPolicySource? { energyState.source }

    /// The highest rate its ambient clients may ask of the link (``EnergyPolicy/ambientMaxFPS``: 30
    /// under the saver); nil while uncapped.
    public var ambientCap: Int? { energyState.cap }

    /// The displays sleep (``EnergyPolicy/screensAsleep``): its ambient clients wait, off the link.
    public var screensAsleep: Bool { energyState.screensAsleep }

    /// Owners of the active ambient clients that wait while the displays sleep.
    public var asleepClients: [String] {
        energyState.asleep.values.map(\.owner).sorted()
    }

    /// The rate it asks of its display's link (nil while idle): ``frameRate`` with an ambient rate
    /// capped at ``ambientCap`` under the saver, and, while its clock does not follow client rates
    /// (``DisplayClock/followsClientRates``), every other rate at ``FrameRate/motion``.
    public var linkRate: FrameRate? {
        frameRate.map { $0.onLink(followingClasses: displayClock.followsClientRates, ambientCap: ambientCap) }
    }

    /// Follows `energy` from now on: its ambient clients ask for at most the policy's
    /// ``EnergyPolicy/ambientMaxFPS`` and stop while ``EnergyPolicy/screensAsleep``.
    func follow(_ energy: EnergyPolicySource) {
        guard energy !== energyState.source else { return }
        energyState.source = energy
        energyState.link = MainActorEnergyLink(energy) { [weak self] policy in self?.energyPolicyDidChange(policy) }
        energyPolicyDidChange(energy.policy)
    }

    /// Takes a new policy: a new cap asks its display for a rate again (a lower one applies after
    /// ``DisplayClock/framesBeforeLowering`` frames, a higher one at once), and the displays going to
    /// sleep or waking stops or restarts its ambient clients.
    func energyPolicyDidChange(_ policy: EnergyPolicy) {
        if policy.ambientMaxFPS != energyState.cap {
            energyState.cap = policy.ambientMaxFPS
            if let display, frameRate != nil { displayClock.frameRateDidChange(on: display) }
        }
        guard policy.screensAsleep != energyState.screensAsleep else { return }
        energyState.screensAsleep = policy.screensAsleep
        if policy.screensAsleep { sleepAmbientClients() } else { wakeAmbientClients() }
    }

    /// Whether `client`, activating, waits for the displays to wake (an ambient client while they
    /// sleep): it is held in ``AmbientEnergyState/asleep``, off the link.
    func waitsForScreens(_ client: FrameClient) -> Bool {
        guard energyState.screensAsleep, client.rate.isAmbient else { return false }
        energyState.asleep[ObjectIdentifier(client)] = client
        return true
    }

    /// The scheduler went away: its waiting ambient clients go idle without calling back.
    func detachAsleep() {
        for client in energyState.asleep.values { client.detach() }
        energyState.asleep.removeAll()
    }

    /// The displays went to sleep: its active ambient clients leave it (it leaves its display when
    /// nothing else ticks) and wait.
    private func sleepAmbientClients() {
        for client in clients.values where client.rate.isAmbient {
            deactivate(client)
            energyState.asleep[ObjectIdentifier(client)] = client
        }
    }

    /// The displays woke: the ambient clients still active tick again from the next frame.
    private func wakeAmbientClients() {
        let waking = Array(energyState.asleep.values)
        energyState.asleep.removeAll()
        for client in waking where client.isActive { activate(client) }
    }
}

extension FrameRate {
    /// A decorative rate (``ambient``, ``slow(_:)``): a loop or a stepping indicator, opt-in per client
    /// and owner-reviewed. Energy Saver caps it and it stops while the displays sleep; ``motion`` and
    /// ``ui`` never change.
    public var isAmbient: Bool {
        switch self {
        case .ambient, .slow: true
        case .motion, .ui: false
        }
    }

    /// The rate a link runs at for a client at this rate. Under Energy Saver (`ambientCap` set) an
    /// ambient rate runs at its own rate, at most `ambientCap`; any other rate runs at itself while
    /// `followingClasses` (``DisplayClock/followsClientRates``), else at ``motion``. A lower rate never
    /// maps above a higher one, so the link rate of a scheduler's highest client is the highest of its
    /// clients' link rates.
    func onLink(followingClasses: Bool, ambientCap: Int?) -> FrameRate {
        if isAmbient, let ambientCap { return hertz > Float(ambientCap) ? .slow(ambientCap) : self }
        return followingClasses ? self : .motion
    }
}
