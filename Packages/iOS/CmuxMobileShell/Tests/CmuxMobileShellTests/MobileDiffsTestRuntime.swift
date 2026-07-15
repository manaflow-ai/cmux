import CMUXMobileCore
import CmuxMobileRPC
import Foundation

struct MobileDiffsTestRuntime: MobileSyncRuntime {
    let transportFactory: any CmxByteTransportFactory
    let supportedRouteKinds: [CmxAttachTransportKind] = [.debugLoopback]
    let rpcRequestTimeoutNanoseconds: UInt64 = 5_000_000_000
    let pairingRequestTimeoutNanoseconds: UInt64 = 5_000_000_000
    let supportsServerPushEvents = false
    let now: @Sendable () -> Date = Date.init
    let stackAccessTokenProvider: @Sendable () async throws -> String = { "test-stack-token" }
    let stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "test-stack-token" }
}
