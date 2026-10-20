import CmuxNextApps
import CmuxNextDaemon
import Foundation

nonisolated extension CloudCredentialRelay {
    /// The allow list is `cmux/cloud`'s only because only `cmux/cloud` may
    /// call this relay (``answer(_:)`` refuses every other app); a second
    /// app that may call it needs its own allow list here.
    ///
    /// The ops the bundled `cmux/cloud` manifest serves (`serves.ops`), the
    /// ones its server sends as wire calls. Empty when the bundle has no such
    /// manifest, so the relay then refuses every op. Read from disk once,
    /// off the main actor.
    @concurrent static func bundledServedOps() async -> Set<String> { servedOpsOfBundledApp }

    private static let servedOpsOfBundledApp: Set<String> = {
        guard let manifest = AppPlatformResources.firstPartyManifests().first(where: { $0.manifest.id == app })?.manifest
        else { return [] }
        return Set(manifest.raw["serves"]?["ops"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }()
}
