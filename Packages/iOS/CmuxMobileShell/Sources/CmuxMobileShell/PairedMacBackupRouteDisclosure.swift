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
}
