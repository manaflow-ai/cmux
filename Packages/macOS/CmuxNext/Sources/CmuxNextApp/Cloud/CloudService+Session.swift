import CmuxNextCloud
import CmuxNextCompat

extension CloudService {
    func makeSessionLifecycle() -> CloudSessionLifecycle {
        let auth = auth
        return CloudSessionLifecycle(current: { auth.coordinator.isAuthenticatedSessionIdentityCurrent($0) },
            fence: { [weak self] in self?.fenceCloudSession() ?? Task {} },
            start: { [weak self] in await self?.startCloudSession($0) },
            retire: { [weak self] in await self?.retireCloudSession($0) })
    }

    func isCloudSessionCurrent(_ identity: CloudSessionLifecycle.Identity) -> Bool {
        guard !isSigningOut, auth.coordinator.isAuthenticatedSessionIdentityCurrent(identity) else { return false }
        return sessionLifecycle?.isCurrent(identity) ?? (configuration.linkSource == .legacy)
    }

    func observeCloudSessions() async {
        if let sessionLifecycle {
            let identities = auth.coordinator.authenticatedSessionIdentities()
            await auth.awaitRestored()
            for await identity in identities {
                guard !Task.isCancelled else { return }
                // The lifecycle owns and joins the worker; keep receiving identity changes during a held startup.
                _ = sessionLifecycle.update(identity)
            }
        } else {
            // The frozen legacy route retains its existing hub/revoke lifetime.
            await auth.awaitRestored()
            for await signedIn in ObservationStream({ self.auth.isSignedIn }) {
                if signedIn {
                    guard auth.isSignedIn, !isSigningOut, !Task.isCancelled else { continue }
                    await hub?.resume()
                    await installSignedIn()
                    hands.start()
                    await refresh()
                } else {
                    dropAllMachines()
                    await endCredentialSession()
                    await installIdentity.unbind()
                    hands.stop()
                }
            }
        }
    }

    /// Close admission synchronously; local transport stops while an old startup finishes draining.
    private func fenceCloudSession() -> Task<Void, Never> {
        let authority = authoritySession?.fence()
        credentialProvider?.suspend()
        dropAllMachines()
        hands.stop()
        let native = nativeLink
        let stopping = Task { await native?.suspend() }
        // task-owner: the lifecycle's fencing task joins both local stop and credential work.
        return Task { [weak self] in
            await self?.endCredentialSession()
            await stopping.value
            await authority?.value
        }
    }

    /// Each awaited startup stage remains bound to the original session.
    private func startCloudSession(_ identity: CloudSessionLifecycle.Identity) async {
        guard isCloudSessionCurrent(identity), mayCallCloud, !Task.isCancelled else { return }
        if let authoritySession {
            if authoritySession.beginRegistration(identity) { await installSignedIn() }
            guard isCloudSessionCurrent(identity), !policyDisabled else { return }
            do { try await authoritySession.start(identity) }
            catch {
                logger.info("Cloud authority observation refused: \(String(describing: error), privacy: .public)")
                return
            }
        }
        guard isCloudSessionCurrent(identity), !policyDisabled else { return }
        await nativeLink?.resume()
        guard isCloudSessionCurrent(identity), !policyDisabled else { return }
        await beginCredentialSession(identity: identity)
        guard isCloudSessionCurrent(identity), !policyDisabled else { return }
        await hub?.resume()
        guard isCloudSessionCurrent(identity), !policyDisabled else { return }
        hands.start()
        await refresh()
    }

    /// A session change closes credentials and local work before unbinding its signer.
    func retireCloudSession(_ reason: CloudSessionLifecycle.Retirement) async {
        await authoritySession?.retire().value
        dropAllMachines()
        hands.stop()
        await endCredentialSession()
        switch reason {
        case .session: await nativeLink?.end()
        case .quit: await nativeLink?.suspend()
        }
        await installIdentity.unbind()
    }
}
