import CmuxAuthRuntime
import CmuxNextCloud

@MainActor
final class CloudSessionLifecycleWorld {
    var selected: AuthenticatedSessionIdentity?
    private(set) var events: [String] = []
    private(set) var live: AuthenticatedSessionIdentity?
    private var hold = false
    private var pending: CheckedContinuation<Void, Never>?
    private let held = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    lazy var lifecycle = CloudSessionLifecycle(current: { [weak self] in self?.selected == $0 },
        start: { [weak self] in await self?.start($0) },
        retire: { [weak self] in self?.retire($0) })

    func choose(_ account: String, generation: UInt64) -> AuthenticatedSessionIdentity {
        let identity = AuthenticatedSessionIdentity(generation: generation, accountID: account)
        selected = identity
        return identity
    }

    func holdStart() { hold = true }
    func waitUntilHeld() async { var i = held.stream.makeAsyncIterator(); _ = await i.next() }
    func release() { pending?.resume(); pending = nil }

    private func label(_ identity: AuthenticatedSessionIdentity) -> String { "\(identity.accountID):\(identity.generation)" }
    private func start(_ identity: AuthenticatedSessionIdentity) async {
        events.append("begin " + label(identity))
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
        events.append(reason == .quit ? "quit" : "retire")
    }
}
