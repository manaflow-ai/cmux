import Foundation
import OSLog

private let mobileHostNetworkStatusLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "mobile-host"
)

extension MobileHostService {
    /// Returns the `mobile.host.status` reply for a network caller.
    ///
    /// Status is the one unauthenticated verb, so a tokenless request receives
    /// the cached identity-free payload without touching the main actor or Stack
    /// verifier. A request that presents the owner's same-account Stack token is
    /// verified and receives the Mac identity that a freshly QR-paired phone uses
    /// to bind its paired-Mac record. Verification failures degrade to the public
    /// payload so reachability remains observable while authorized verbs surface
    /// the actual auth failure.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated func networkStatusResult(
        for request: MobileHostRPCRequest
    ) async -> MobileHostRPCResult {
        let trimmedToken = request.auth?.stackAccessToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedToken?.isEmpty == false else {
            return MobileHostPublicStatusCache.result(includeIdentity: false)
        }
        let verified = await verifiedStackCaller(for: request)
        if !verified {
            mobileHostNetworkStatusLog.error(
                "mobile host status identity withheld: stack verification failed"
            )
        }
        return MobileHostPublicStatusCache.result(includeIdentity: verified)
    }
}
