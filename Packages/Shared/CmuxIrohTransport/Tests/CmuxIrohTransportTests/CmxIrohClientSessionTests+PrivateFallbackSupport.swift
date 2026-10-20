import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

extension CmxIrohClientSessionTests {
    func privateFallbackAuthorization(
        for hints: [CmxIrohPathHint]
    ) throws -> CmxIrohPrivateFallbackAuthorization {
        let profiles = Set(hints.compactMap(\.networkProfile))
        let admittedAt = hints.compactMap(\.observedAt).min()?.addingTimeInterval(1) ?? Date()
        return try CmxIrohPrivateFallbackAuthorization(
            networkPathSnapshot: CmxIrohNetworkPathSnapshot(
                generation: 7,
                activeNetworkProfiles: profiles
            ),
            pathHints: hints,
            admittedAt: admittedAt
        )
    }
}

actor TestPrivateFallbackValidator: CmxIrohPrivateFallbackValidating {
    private let error: CmxIrohPrivateFallbackValidationError?
    private var authorizations: [CmxIrohPrivateFallbackAuthorization] = []

    init(error: CmxIrohPrivateFallbackValidationError? = nil) {
        self.error = error
    }

    func validatePrivateFallback(
        _ authorization: CmxIrohPrivateFallbackAuthorization
    ) throws {
        authorizations.append(authorization)
        if let error {
            throw error
        }
    }

    func observedAuthorizations() -> [CmxIrohPrivateFallbackAuthorization] {
        authorizations
    }
}
