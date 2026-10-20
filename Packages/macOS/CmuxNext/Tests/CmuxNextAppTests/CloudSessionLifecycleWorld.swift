import CmuxNextCloud

@MainActor
final class CloudSessionLifecycleWorld {
    var selected: CloudSessionLifecycle.Identity?
    private(set) var events: [String] = []
    private(set) var live: CloudSessionLifecycle.Identity?
    private(set) var admissionOpen = false
    private(set) var fences = 0
    private var hold = false
    private var pending: CheckedContinuation<Void, Never>?
    private let held = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    lazy var lifecycle = CloudSessionLifecycle(current: { [weak self] in self?.selected == $0 },
        fence: { [weak self] in
            self?.admissionOpen = false; self?.fences += 1
            return Task {}
        },
        start: { [weak self] in await self?.start($0) },
        retire: { [weak self] in self?.retire($0) })

    func choose(_ account: String, generation: UInt64) -> CloudSessionLifecycle.Identity {
        let identity = CloudSessionLifecycle.Identity(generation: generation, accountID: account)
        selected = identity
        return identity
    }

    func holdStart() { hold = true }
    func waitUntilHeld() async { var i = held.stream.makeAsyncIterator(); _ = await i.next() }
    func release() { pending?.resume(); pending = nil }

    private func label(_ identity: CloudSessionLifecycle.Identity) -> String { "\(identity.accountID):\(identity.generation)" }
    private func start(_ identity: CloudSessionLifecycle.Identity) async {
        events.append("begin " + label(identity))
        admissionOpen = lifecycle.isCurrent(identity)
        if hold {
            hold = false
            await withCheckedContinuation { pending = $0; held.continuation.yield(()) }
        }
        if lifecycle.isCurrent(identity) {
            live = identity
            events.append("ready " + label(identity))
        } else { events.append("refused " + label(identity)) }
    }

    private func retire(_ reason: CloudSessionLifecycle.Retirement) {
        live = nil
        admissionOpen = false
        events.append(reason == .quit ? "quit" : "retire")
    }
}
