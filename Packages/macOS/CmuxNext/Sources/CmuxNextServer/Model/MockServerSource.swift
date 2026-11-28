public import Foundation

/// A self-contained server for demos, screenshots and tests: one canned
/// scenario, intents applied and echoed on the next main-actor turn (no
/// timers). Records every intent it receives.
@MainActor
public final class MockServerSource: ServerSource {
    public private(set) var snapshot: ServerSnapshot
    /// Every intent received, in order.
    public private(set) var received: [ServerIntent] = []
    /// When false, intents wait for `deliverHeld()` (tests).
    public var echoImmediately = true
    /// The time the mock stamps on resolves and new codes.
    public var clock: () -> Date

    private var sink: (@MainActor (ServerSourceEvent) -> Void)?
    private var held: [ServerIntent] = []

    public init(scenario: MockServerScenario = .healthyMac, now: Date = MockServerScenario.referenceDate) {
        snapshot = scenario.snapshot(now: now)
        clock = { now }
    }

    public func start(_ sink: @escaping @MainActor (ServerSourceEvent) -> Void) {
        self.sink = sink
        sink(.connection(.connected))
        sink(.snapshot(snapshot))
    }

    public func stop() {
        sink = nil
    }

    public func send(_ intent: ServerIntent) {
        received.append(intent)
        if echoImmediately {
            Task { @MainActor [weak self] in self?.commit(intent) }
        } else {
            held.append(intent)
        }
    }

    /// Applies held intents now (tests).
    public func deliverHeld() {
        let intents = held
        held = []
        intents.forEach(commit)
    }

    /// Swaps the whole scenario (demo switcher), as a fresh owner snapshot.
    public func load(_ scenario: MockServerScenario) {
        snapshot = scenario.snapshot(now: clock())
        sink?(.snapshot(snapshot))
    }

    public func disconnect(_ reason: String) {
        sink?(.connection(.unavailable(reason)))
    }

    private func commit(_ intent: ServerIntent) {
        var reject: String?
        switch intent.kind {
        case let .setEnabled(on):
            snapshot.enabled = on
            for index in snapshot.roles.indices where snapshot.roles[index].role != .automations {
                snapshot.roles[index].state = on ? .on : .off
            }
        case .showPairingCode:
            if !snapshot.pairing.isPaired {
                snapshot.pairing = .unpaired(MockServerScenario.offer(now: clock()))
            }
        case let .lookupCode(code):
            let found = code == MockServerScenario.offerCode ? MockServerScenario.candidate : nil
            sink?(.candidate(found))
            if found == nil { reject = "No server is waiting with that code." }
        case .approveCode, .openHealth:
            break
        case let .fixCheck(check):
            if let index = snapshot.alerts.firstIndex(where: { $0.check == check && $0.isOpen }) {
                snapshot.alerts[index].resolvedAt = clock()
            }
        case let .revokeDevice(id):
            snapshot.devices.removeAll { $0.id == id }
        }
        sink?(.snapshot(snapshot))
        sink?(.settled(key: intent.key, reject: reject))
    }
}
