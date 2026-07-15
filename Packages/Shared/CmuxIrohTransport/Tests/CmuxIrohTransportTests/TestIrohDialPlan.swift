import CMUXMobileCore
import Foundation

func testIrohDialPlan(
    publicPaths: [CmxIrohPathHint] = [],
    privateFallbackPaths: [CmxIrohPathHint] = []
) throws -> CmxIrohDialPlan {
    let identity = try CmxIrohPeerIdentity(
        endpointID: String(repeating: "01", count: 32)
    )
    let endpoint = CmxAttachEndpoint.peer(
        identity: identity,
        pathHints: publicPaths + privateFallbackPaths
    )
    let now = privateFallbackPaths
        .compactMap(\.observedAt)
        .min()?
        .addingTimeInterval(1) ?? Date()
    let managedRelayURLs = Set(publicPaths.compactMap { hint in
        hint.kind == .relayURL ? hint.value : nil
    })
    let activeNetworkProfiles = Set(privateFallbackPaths.compactMap(\.networkProfile))

    guard let dialPlan = endpoint.irohDialPlan(
        at: now,
        managedRelayURLs: managedRelayURLs,
        activeNetworkProfiles: activeNetworkProfiles
    ) else {
        preconditionFailure("A peer endpoint must produce an Iroh dial plan")
    }
    return dialPlan
}
