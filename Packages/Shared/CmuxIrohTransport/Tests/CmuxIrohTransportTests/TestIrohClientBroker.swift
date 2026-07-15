import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

actor TestIrohClientBroker: CmxIrohClientBrokerServing {
    private let registration: CmxIrohRegistrationResponse
    private let discoveryResponse: CmxIrohDiscoveryResponse
    private let relayResponse: CmxIrohRelayTokenResponse
    private let revokeError: (any Error)?
    private let registrationHook: (@Sendable (_ count: Int) async -> Void)?
    private var registrationError: (any Error)?
    private var preparedRegistrations: [CmxIrohPreparedRegistration] = []
    private var revokedBindingIDs: [String] = []
    private var relayIssueCount = 0
    private var registrationCountWaiters: [
        UUID: (minimum: Int, continuation: CheckedContinuation<Void, Never>)
    ] = [:]

    init(
        binding: CmxIrohBrokerBinding,
        discovery: CmxIrohDiscoveryResponse,
        relay: CmxIrohRelayTokenResponse,
        issueRelayAtRegistration: Bool = true,
        registrationError: (any Error)? = nil,
        revokeError: (any Error)? = nil,
        registrationHook: (@Sendable (_ count: Int) async -> Void)? = nil
    ) {
        registration = CmxIrohRegistrationResponse(
            binding: binding,
            relay: issueRelayAtRegistration ? .issued(relay) : .unavailable
        )
        discoveryResponse = discovery
        relayResponse = relay
        self.revokeError = revokeError
        self.registrationError = registrationError
        self.registrationHook = registrationHook
    }

    func register(
        prepared: CmxIrohPreparedRegistration,
        signer _: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse {
        preparedRegistrations.append(prepared)
        let count = preparedRegistrations.count
        let readyIDs = registrationCountWaiters.compactMap { id, waiter in
            count >= waiter.minimum ? id : nil
        }
        for id in readyIDs {
            registrationCountWaiters.removeValue(forKey: id)?.continuation.resume()
        }
        await registrationHook?(count)
        if let registrationError { throw registrationError }
        return registration
    }

    func discover() -> CmxIrohDiscoveryResponse {
        discoveryResponse
    }

    func issuePairGrant(
        initiatorBindingID _: String,
        acceptorBindingID _: String
    ) throws -> CmxIrohPairGrantResponse {
        throw TestIrohTransportError.unsupported
    }

    func issueRelayToken(
        bindingID _: String,
        endpointID _: CmxIrohPeerIdentity
    ) -> CmxIrohRelayTokenResponse {
        relayIssueCount += 1
        return relayResponse
    }

    func revoke(bindingID: String) throws {
        revokedBindingIDs.append(bindingID)
        if let revokeError { throw revokeError }
    }

    func observedRegistrations() -> [CmxIrohPreparedRegistration] {
        preparedRegistrations
    }

    func observedRevokedBindingIDs() -> [String] {
        revokedBindingIDs
    }

    func observedRelayIssueCount() -> Int {
        relayIssueCount
    }

    func setRegistrationError(_ error: (any Error)?) {
        registrationError = error
    }

    func waitForRegistrationCount(_ minimum: Int) async {
        if preparedRegistrations.count >= minimum { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    registrationCountWaiters[id] = (minimum, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelRegistrationWaiter(id) }
        }
    }

    func waitForRegistrationCount(_ minimum: Int, timeout: Duration) async -> Bool {
        if preparedRegistrations.count >= minimum { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForRegistrationCount(minimum)
                return !Task.isCancelled
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: timeout)
                } catch {
                    return false
                }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func cancelRegistrationWaiter(_ id: UUID) {
        registrationCountWaiters.removeValue(forKey: id)?.continuation.resume()
    }
}
