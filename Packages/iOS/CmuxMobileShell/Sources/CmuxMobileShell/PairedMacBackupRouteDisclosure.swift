import CMUXMobileCore
import Foundation

/// Applies the paired-Mac backup disclosure boundary to one route collection.
struct PairedMacBackupRouteDisclosure {
    let routes: [CmxAttachRoute]

    func cloudSafe(at now: Date) -> [CmxAttachRoute] {
        routes.compactMap { route in
            route.disclosed(for: .pairedMacCloudBackup, at: now)
        }
    }

    func cloudPrivacySafe() -> [CmxAttachRoute] {
        routes.compactMap { route in
            guard route.kind != .lan else {
                // LAN host/port coordinates are device-local and must stay out
                // of restored cloud-backup records as well as fresh uploads.
                return nil
            }
            guard case let .peer(identity, pathHints) = route.endpoint else {
                return route
            }
            let publicHints = pathHints.filter {
                $0.privacyScope == .publicInternet && $0.isSafeForCurrentWireFormat
            }
            return try? CmxAttachRoute(
                id: route.id,
                kind: route.kind,
                endpoint: .peer(identity: identity, pathHints: publicHints),
                priority: route.priority
            )
        }
    }
}
