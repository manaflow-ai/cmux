internal import CMUXMobileCore
import Foundation

struct CmxIrohRegistryPathMerger {
    static func merge(
        primary: [CmxIrohPathHint],
        fallback: [CmxIrohPathHint],
        at now: Date,
        managedRelayURLs: Set<String>,
        activeNetworkProfiles: Set<CmxIrohNetworkProfileKey>
    ) -> [CmxIrohPathHint] {
        var result: [CmxIrohPathHint] = []
        for hint in primary + fallback where hint.isUsable(at: now) {
            guard isEligible(
                hint,
                managedRelayURLs: managedRelayURLs,
                activeNetworkProfiles: activeNetworkProfiles
            ) else {
                continue
            }
            if !result.contains(where: { sameRoute($0, hint) }) {
                result.append(hint)
            }
            if result.count == CmxAttachEndpoint.maximumIrohPathHintCount { break }
        }
        return result
    }

    private static func isEligible(
        _ hint: CmxIrohPathHint,
        managedRelayURLs: Set<String>,
        activeNetworkProfiles: Set<CmxIrohNetworkProfileKey>
    ) -> Bool {
        if hint.privacyScope != .publicInternet {
            guard let profile = hint.networkProfile else { return false }
            return activeNetworkProfiles.contains(profile)
        }
        switch hint.kind {
        case .directAddress:
            return true
        case .relayURL:
            return managedRelayURLs.contains(hint.value)
        case .relayIdentifier:
            return false
        }
    }

    private static func sameRoute(
        _ left: CmxIrohPathHint,
        _ right: CmxIrohPathHint
    ) -> Bool {
        left.kind == right.kind
            && left.value == right.value
            && left.source == right.source
            && left.privacyScope == right.privacyScope
            && left.networkProfile == right.networkProfile
    }
}
