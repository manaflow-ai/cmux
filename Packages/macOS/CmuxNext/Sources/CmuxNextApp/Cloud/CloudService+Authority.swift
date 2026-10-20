import CmuxNextCloud

extension CloudService {
    func makeAuthoritySession() -> CloudAuthoritySession {
        let scope = teamScope
        let transport = CloudAuthorityWireTransport(origin: configuration.ownerAPIBaseURL(), headers: installIdentity.requestHeaders)
        return CloudAuthoritySession(capability: observedAuthority, initial: { try await scope.bind() },
            current: { [weak self] identity in
                guard let self else { return false }
                return self.isCloudSessionCurrent(identity) && !self.policyDisabled
            }, lost: { [weak self] identity, restart in
                _ = self?.sessionLifecycle?.authorityChanged(identity, restart: restart)
            }, make: { scope in
                CloudAuthorityObservation(scopeID: scope.id, team: scope.team, leases: scope.wireLeases,
                    recheck: scope.recheck, connect: { try transport.connect($0) })
            })
    }
}
