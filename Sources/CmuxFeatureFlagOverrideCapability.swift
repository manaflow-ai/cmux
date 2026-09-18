import CmuxSettings
import Foundation

/// Grants the Cloud-only dogfood exception from the installed app identity.
/// Display names, environment variables and persisted defaults cannot grant it.
struct CmuxFeatureFlagOverrideCapability: Equatable, Sendable {
    let allowsCloudOverride: Bool
    let enablesCloudDogfood: Bool
    let isDebugBuild: Bool
    let isTaggedDebugArtifact: Bool

    init(bundle: Bundle = .main) {
        #if DEBUG
        self.init(bundleIdentifier: bundle.bundleIdentifier, isDebugBuild: true,
                  cloudDogfoodRequested: bundle.object(forInfoDictionaryKey: "CMUXCloudDogfoodEnabled") as? Bool == true)
        #else
        self.init(bundleIdentifier: bundle.bundleIdentifier, isDebugBuild: false)
        #endif
    }

    init(bundleIdentifier: String?, isDebugBuild: Bool, cloudDogfoodRequested: Bool = false) {
        self.isDebugBuild = isDebugBuild
        // Only the shipping Nightly identity grants the exception in Release.
        // Debug also requires a debug bundle, so stable/staging identities fail closed.
        let debugID = SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier
        isTaggedDebugArtifact = isDebugBuild && bundleIdentifier?.hasPrefix(debugID + ".") == true
        allowsCloudOverride = bundleIdentifier == SocketPathMarkerFiles.nightlyBundleIdentifier
            || (isDebugBuild && (bundleIdentifier == debugID
                || bundleIdentifier?.hasPrefix(debugID + ".") == true))
        enablesCloudDogfood = cloudDogfoodRequested && isDebugBuild
            && bundleIdentifier?.hasPrefix(debugID + ".") == true
    }

    func policy(for definition: CmuxFeatureFlagDefinition) -> CmuxFeatureFlagOverridePolicy {
        guard definition.key == CmuxFeatureFlags.cloudMachinesFlag.key else { return .remoteFirst }
        return allowsCloudOverride ? .localFirst : .disabled
    }
}
