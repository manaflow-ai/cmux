import Foundation
@testable import CmuxNextApp
@testable import CmuxNextCloud

/// Composes the real lifecycle, owner observer, capability and daemon credential provider.
@MainActor
final class CloudAuthoritySessionTestWorld {
    let base: CloudObservedAuthorityTestWorld
    let wire = CloudAuthoritySessionTestWire()
    let daemon = CloudCredentialProviderWorld()
    let provider: CloudCredentialProvider
    let startupGate = CloudObservedAuthorityTestGate()
    var holdStartup = false
    private(set) var starts = 0
    private(set) var losses = 0
    private(set) var failures = 0
    private(set) var refused = 0
    private let loss = AsyncStream<Int>.makeStream()

    lazy var lifecycle = CloudSessionLifecycle(current: { [weak self] in self?.base.identity == $0 },
        fence: { [weak self] in self?.fence() ?? Task {} },
        start: { [weak self] in await self?.start($0) }, retire: { [weak self] _ in await self?.retire() })

    lazy var authority = makeAuthority()

    private func makeAuthority() -> CloudAuthoritySession {
        let scopes = base.scopes, wire = wire
        return CloudAuthoritySession(capability: base.observed, initial: { try await scopes.bind() },
            current: { [weak self] in self?.lifecycle.isCurrent($0) == true },
            lost: { [weak self] identity, restart in
                guard let self else { return }
                self.losses += 1; self.loss.continuation.yield(self.losses)
                _ = self.lifecycle.authorityChanged(identity, restart: restart)
            }, make: { wire.make($0) })
    }

    init(root: URL) {
        base = CloudObservedAuthorityTestWorld(root: root)
        provider = daemon.provider()
        provider.suspend()
    }

    func register() async -> Bool {
        await provider.register(userOriginAllowed: true, send: { await self.daemon.register($0) },
            invalidate: { try await self.daemon.invalidate($0) })
    }

    func waitForLoss() async {
        var iterator = loss.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    private func fence() -> Task<Void, Never> {
        let drain = authority.fence()
        provider.suspend()
        return Task {
            await self.provider.endSession { try await self.daemon.invalidate($0) }
            await drain.value
        }
    }

    private func start(_ identity: CloudSessionLifecycle.Identity) async {
        starts += 1
        do {
            if authority.beginRegistration(identity) {
                try await base.install.signedIn(stackUser: identity.accountID, session: { "test-session" })
            }
            try await authority.start(identity)
            if holdStartup { holdStartup = false; await startupGate.hold() }
            guard lifecycle.isCurrent(identity), (try? base.observed.snapshot()) != nil else { refused += 1; return }
            provider.beginSession()
            _ = await register()
        } catch { failures += 1 }
    }

    private func retire() async {
        await authority.retire().value
        await provider.endSession { try await self.daemon.invalidate($0) }
        await base.install.unbind()
    }

    func stop() async {
        await startupGate.release()
        await lifecycle.stop().value
        await wire.clock.finish()
    }
}
