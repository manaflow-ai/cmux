import Foundation

extension CmuxFeatureFlags {
    // FLAG(key: cloud-machines-enabled-release, owner: austinwang,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
    // The release fallback stays off. Recognized DEBUG bundles install an
    // in-memory local override during initialization so dev builds still
    // dogfood Cloud when the remote rollout is unavailable or false.
    nonisolated static let cloudMachinesFlag = CmuxFeatureFlagDefinition(
        key: "cloud-machines-enabled-release",
        title: String(localized: "featureFlags.cloudMachines.title", defaultValue: "Cloud Machines"),
        flagDescription: String(
            localized: "featureFlags.cloudMachines.description",
            defaultValue: "Enables the macOS Cloud Machines integration, including entry points, attachments, and background sync."
        ),
        defaultWhenUnavailable: false
    )

    var isCloudMachinesEnabled: Bool { effectiveValue(for: Self.cloudMachinesFlag) }
}
