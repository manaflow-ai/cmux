import Foundation

extension CmuxFeatureFlags {
    // FLAG(key: cloud-machines-enabled-release, owner: austinwang,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: true)
    // Remote kill switch for the macOS Cloud integration. DEBUG keeps the fallback
    // enabled for dogfood; release keeps Cloud unavailable until rollout.
    nonisolated static let cloudMachinesFlag = CmuxFeatureFlagDefinition(
        key: "cloud-machines-enabled-release",
        title: String(localized: "featureFlags.cloudMachines.title", defaultValue: "Cloud Machines"),
        flagDescription: String(
            localized: "featureFlags.cloudMachines.description",
            defaultValue: "Enables the macOS Cloud Machines integration, including entry points, attachments, and background sync."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.cloudMachinesDefault
    )

    var isCloudMachinesEnabled: Bool { effectiveValue(for: Self.cloudMachinesFlag) }
}
