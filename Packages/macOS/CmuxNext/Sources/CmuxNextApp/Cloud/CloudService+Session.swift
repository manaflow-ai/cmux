import CmuxAuthRuntime
import CmuxNextCloud

extension CloudService {
    func makeSessionLifecycle() -> CloudSessionLifecycle {
        let auth = auth
        return CloudSessionLifecycle(current: { auth.coordinator.isAuthenticatedSessionIdentityCurrent($0) },
            start: { [weak self] in await self?.startCloudSession($0) },
            retire: { [weak self] in await self?.retireCloudSession($0) })
    }

    func isCloudSessionCurrent(_ identity: AuthenticatedSessionIdentity) -> Bool {
        !isSigningOut && sessionLifecycle?.isCurrent(identity) == true
    }

    /// Each awaited startup stage remains bound to the original session.
    private func startCloudSession(_ identity: AuthenticatedSessionIdentity) async {
        guard isCloudSessionCurrent(identity), !policyDisabled, !Task.isCancelled else { return }
        await nativeLink?.resume()
        guard isCloudSessionCurrent(identity), !policyDisabled else { return }
        await beginCredentialSession(identity: identity)
        guard isCloudSessionCurrent(identity), !policyDisabled else { return }
        await hub?.resume()
        guard isCloudSessionCurrent(identity), !policyDisabled else { return }
        await installSignedIn()
        guard isCloudSessionCurrent(identity), !policyDisabled else { return }
        hands.start()
        await refresh()
    }

    /// A session change closes credentials and local work before unbinding its signer.
    func retireCloudSession(_ reason: CloudSessionLifecycle.Retirement) async {
        dropAllMachines()
        hands.stop()
        await endCredentialSession()
        switch reason {
        case .session: await nativeLink?.end()
        case .quit: await nativeLink?.suspend()
        }
        await hub?.stop()
        await installIdentity.unbind()
    }
}
